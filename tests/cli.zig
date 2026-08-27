const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const zova = @import("zova");

test "cli version and help are successful" {
    var result = try runCli(&.{ "zova", "--version" });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, cli.package_version) != null);

    var help = try runCli(&.{ "zova", "--help" });
    defer help.deinit();
    try std.testing.expectEqual(@as(u8, 0), help.code);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "zova [--extension <bundle.zovaext> ...] <command>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "info <file.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "objects [--json] [--limit <n>] <file.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "object [--json] [--limit <n>] <file.zova> <object-id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "chunks [--json] [--limit <n>] <file.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "chunk [--json] [--limit <n>] <file.zova> <chunk-id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "vectors [--json] [--limit <n>] <file.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "vector-collection [--json] [--limit <n>] <file.zova> <name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "tables [--json] [--limit <n>] <file.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "format [--json] <database.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "migrate [--json] [--no-verify] <source.zova> <destination.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "check [--deep] <file.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "backup [--json] [--no-verify] <source.zova> <destination.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "compact [--json] [--no-verify] <source.zova> <destination.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "restore [--json] [--no-verify] <backup.zova> <destination.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "split (--objects | --vectors | --graphs) [--json] <main.zova> <store.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "doctor [--json] [--limit <n>] <file.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "salvage --dry-run [--json] [--limit <n>] <source.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "salvage [--json] [--limit <n>] <source.zova> <destination.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "object-store create [--json] <objects.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "object-store bind [--json] <main.zova> <objects.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "object-store info [--json] <main.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "object-store unbind [--json] <main.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "object-store rebind") == null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "vector-store create [--json] <vectors.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "vector-store bind [--json] <main.zova> <vectors.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "vector-store info [--json] <main.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "vector-store unbind [--json] <main.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "extension list [--json] <file.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "extension install [--json] <file.zova> <name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "extension trust [--json] <bundle.zovaext>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "extension trusted [--json]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "extension scaffold [--json] <dir> --name <name> --version <version>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "extension build [--json] <dir>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "extension pack [--json] <dir> --out <bundle.zovaext>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "extension verify [--json] [--smoke] <bundle.zovaext>") != null);
}

test "cli usage errors return exit code 2" {
    var unknown = try runCli(&.{ "zova", "wat" });
    defer unknown.deinit();
    try std.testing.expectEqual(@as(u8, 2), unknown.code);
    try std.testing.expect(std.mem.indexOf(u8, unknown.stderr, "unknown command") != null);

    var missing = try runCli(&.{ "zova", "info" });
    defer missing.deinit();
    try std.testing.expectEqual(@as(u8, 2), missing.code);
    try std.testing.expect(std.mem.indexOf(u8, missing.stderr, "usage") != null);
}

test "cli extension host lists checks and rejects unavailable install" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "extensions-cli.zova");

    {
        var db = try zova.Database.create(db_path);
        defer db.deinit();
    }

    var list = try runCli(&.{ "zova", "extension", "list", "--json", db_path });
    defer list.deinit();
    try std.testing.expectEqual(@as(u8, 0), list.code);
    var list_json = try parseJson(list.stdout);
    defer list_json.deinit();
    try expectJsonString(list_json.value.object, "command", "extension-list");
    try expectJsonArrayLen(list_json.value.object, "extensions", 0);

    var check = try runCli(&.{ "zova", "extension", "check", db_path });
    defer check.deinit();
    try std.testing.expectEqual(@as(u8, 0), check.code);
    try expectContains(check.stdout, "extensions: 0");

    var missing = try runCli(&.{ "zova", "extension", "install", "--json", db_path, "missing_ext" });
    defer missing.deinit();
    try std.testing.expectEqual(@as(u8, 4), missing.code);
    try expectContains(missing.stderr, "ExtensionNotFound");

    var invalid_name = try runCli(&.{ "zova", "extension", "info", db_path, "_zova_hidden" });
    defer invalid_name.deinit();
    try std.testing.expectEqual(@as(u8, 2), invalid_name.code);
    try expectContains(invalid_name.stderr, "extension name is invalid");
}

test "cli bundled trgm extension installs checks lists and drops" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "trgm-cli.zova");

    {
        var db = try zova.Database.create(db_path);
        defer db.deinit();
    }

    var install = try runCli(&.{ "zova", "extension", "install", "--json", db_path, "trgm" });
    defer install.deinit();
    try std.testing.expectEqual(@as(u8, 0), install.code);
    var install_json = try parseJson(install.stdout);
    defer install_json.deinit();
    try expectJsonString(install_json.value.object, "command", "extension-install");
    const install_extension = install_json.value.object.get("extension") orelse return error.MissingJsonField;
    try expectJsonString(install_extension.object, "name", "trgm");

    var info = try runCli(&.{ "zova", "extension", "info", "--json", db_path, "trgm" });
    defer info.deinit();
    try std.testing.expectEqual(@as(u8, 0), info.code);
    var info_json = try parseJson(info.stdout);
    defer info_json.deinit();
    const info_extension = info_json.value.object.get("extension") orelse return error.MissingJsonField;
    try expectJsonString(info_extension.object, "name", "trgm");
    try expectJsonString(info_extension.object, "storage_prefix", "_zova_ext_trgm_");

    var check = try runCli(&.{ "zova", "extension", "check", "--json", db_path, "trgm" });
    defer check.deinit();
    try std.testing.expectEqual(@as(u8, 0), check.code);

    var deep_check = try runCli(&.{ "zova", "check", "--json", "--deep", db_path });
    defer deep_check.deinit();
    try std.testing.expectEqual(@as(u8, 0), deep_check.code);
    var deep_check_json = try parseJson(deep_check.stdout);
    defer deep_check_json.deinit();
    try expectJsonObjectHasInt(deep_check_json.value.object, "checked", "extensions");

    var doctor = try runCli(&.{ "zova", "doctor", "--json", db_path });
    defer doctor.deinit();
    try std.testing.expectEqual(@as(u8, 0), doctor.code);
    try expectContains(doctor.stdout, "\"extension\"");

    var doctor_text = try runCli(&.{ "zova", "doctor", db_path });
    defer doctor_text.deinit();
    try std.testing.expectEqual(@as(u8, 0), doctor_text.code);
    try expectContains(doctor_text.stdout, "extensions_checked: 1");

    var drop = try runCli(&.{ "zova", "extension", "drop", "--json", db_path, "trgm" });
    defer drop.deinit();
    try std.testing.expectEqual(@as(u8, 0), drop.code);

    var list = try runCli(&.{ "zova", "extension", "list", "--json", db_path });
    defer list.deinit();
    try std.testing.expectEqual(@as(u8, 0), list.code);
    var list_json = try parseJson(list.stdout);
    defer list_json.deinit();
    try expectJsonArrayLen(list_json.value.object, "extensions", 0);
}

test "cli trusted dynamic extension loads only when explicitly requested" {
    if (comptime !zova.extension_dynamic.supports_dynamic_loading) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = defaultIo();

    try tmp.dir.createDir(io, "dyn_test.zovaext", .default_dir);
    const library_bytes = try std.Io.Dir.cwd().readFileAlloc(io, cli.dynamic_extension_library_path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(library_bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "dyn_test.zovaext/libdyn_test", .data = library_bytes });
    try tmp.dir.writeFile(io, .{
        .sub_path = "dyn_test.zovaext/extension.json",
        .data =
        \\{
        \\  "name": "dyn_test",
        \\  "version": "0.1.0",
        \\  "storage_prefix": "_zova_ext_dyn_test_",
        \\  "zova_abi_min": "0.21.0",
        \\  "capabilities": "sql,dynamic-test",
        \\  "library": "libdyn_test"
        \\}
        ,
    });

    var bundle_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const bundle_path = try std.fmt.bufPrint(&bundle_buffer, ".zig-cache/tmp/{s}/dyn_test.zovaext", .{tmp.sub_path});
    var trust_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const trust_path = try std.fmt.bufPrint(&trust_buffer, ".zig-cache/tmp/{s}/trusted_extensions.json", .{tmp.sub_path});
    try setTestEnv("ZOVA_TRUST_STORE", trust_path);

    var db_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&db_buffer, tmp.sub_path[0..], "dynamic-extension.zova");
    {
        var db = try zova.Database.create(db_path);
        defer db.deinit();
    }

    var untrusted = try runCli(&.{ "zova", "--extension", bundle_path, "extension", "install", "--json", db_path, "dyn_test" });
    defer untrusted.deinit();
    try std.testing.expectEqual(@as(u8, 4), untrusted.code);
    try expectContains(untrusted.stderr, "ExtensionUntrusted");
    try expectContains(untrusted.stderr, "zova extension trust");

    var trust = try runCli(&.{ "zova", "extension", "trust", "--json", bundle_path });
    defer trust.deinit();
    try std.testing.expectEqual(@as(u8, 0), trust.code);
    var trust_json = try parseJson(trust.stdout);
    defer trust_json.deinit();
    try expectJsonString(trust_json.value.object, "command", "extension-trust");

    var trusted = try runCli(&.{ "zova", "extension", "trusted", "--json" });
    defer trusted.deinit();
    try std.testing.expectEqual(@as(u8, 0), trusted.code);
    try expectContains(trusted.stdout, "\"name\": \"dyn_test\"");

    var missing = try runCli(&.{ "zova", "extension", "install", "--json", db_path, "dyn_test" });
    defer missing.deinit();
    try std.testing.expectEqual(@as(u8, 4), missing.code);
    try expectContains(missing.stderr, "ExtensionNotFound");

    var install = try runCli(&.{ "zova", "--extension", bundle_path, "extension", "install", "--json", db_path, "dyn_test" });
    defer install.deinit();
    try std.testing.expectEqual(@as(u8, 0), install.code);

    var normal_check = try runCli(&.{ "zova", "extension", "check", "--json", db_path, "dyn_test" });
    defer normal_check.deinit();
    try std.testing.expectEqual(@as(u8, 4), normal_check.code);
    try expectContains(normal_check.stderr, "ExtensionUnavailable");

    var dynamic_check = try runCli(&.{ "zova", "--extension", bundle_path, "extension", "check", "--json", db_path, "dyn_test" });
    defer dynamic_check.deinit();
    try std.testing.expectEqual(@as(u8, 0), dynamic_check.code);

    var untrust = try runCli(&.{ "zova", "extension", "untrust", "--json", "dyn_test" });
    defer untrust.deinit();
    try std.testing.expectEqual(@as(u8, 0), untrust.code);
    try expectContains(untrust.stdout, "\"removed\": true");

    var after_untrust = try runCli(&.{ "zova", "--extension", bundle_path, "extension", "check", "--json", db_path, "dyn_test" });
    defer after_untrust.deinit();
    try std.testing.expectEqual(@as(u8, 4), after_untrust.code);
    try expectContains(after_untrust.stderr, "ExtensionUntrusted");
}

test "cli experimental extension builder scaffolds builds packs verifies and installs" {
    if (comptime !zova.extension_dynamic.supports_dynamic_loading) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var extension_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const extension_dir = try std.fmt.bufPrint(&extension_dir_buffer, ".zig-cache/tmp/{s}/sample_ext", .{tmp.sub_path});
    var bundle_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const bundle_path = try std.fmt.bufPrint(&bundle_buffer, ".zig-cache/tmp/{s}/sample_ext.zovaext", .{tmp.sub_path});
    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "builder-extension-backup.zova");
    var compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = try testingDbPath(&compact_buffer, tmp.sub_path[0..], "builder-extension-compact.zova");
    var restored_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const restored_path = try testingDbPath(&restored_buffer, tmp.sub_path[0..], "builder-extension-restored.zova");
    var trust_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const trust_path = try std.fmt.bufPrint(&trust_buffer, ".zig-cache/tmp/{s}/trusted_builder_extensions.json", .{tmp.sub_path});
    try setTestEnv("ZOVA_TRUST_STORE", trust_path);

    var scaffold = try runCli(&.{ "zova", "extension", "scaffold", "--json", extension_dir, "--name", "sample_ext", "--version", "0.1.0" });
    defer scaffold.deinit();
    try std.testing.expectEqual(@as(u8, 0), scaffold.code);
    var scaffold_json = try parseJson(scaffold.stdout);
    defer scaffold_json.deinit();
    try expectJsonString(scaffold_json.value.object, "command", "extension-scaffold");
    try expectContains(scaffold.stdout, "\"experimental\": true");

    try expectFileExists(tmp.dir, "sample_ext/extension.zig");
    try expectFileExists(tmp.dir, "sample_ext/extension.json");

    var build = try runCli(&.{ "zova", "extension", "build", "--json", extension_dir });
    defer build.deinit();
    try std.testing.expectEqual(@as(u8, 0), build.code);
    var build_json = try parseJson(build.stdout);
    defer build_json.deinit();
    try expectJsonString(build_json.value.object, "command", "extension-build");

    var pack = try runCli(&.{ "zova", "extension", "pack", "--json", extension_dir, "--out", bundle_path });
    defer pack.deinit();
    try std.testing.expectEqual(@as(u8, 0), pack.code);
    var pack_json = try parseJson(pack.stdout);
    defer pack_json.deinit();
    try expectJsonString(pack_json.value.object, "command", "extension-pack");
    try expectContains(pack.stdout, "zova extension trust");

    var verify = try runCli(&.{ "zova", "extension", "verify", "--json", bundle_path });
    defer verify.deinit();
    try std.testing.expectEqual(@as(u8, 0), verify.code);
    var verify_json = try parseJson(verify.stdout);
    defer verify_json.deinit();
    try expectJsonString(verify_json.value.object, "command", "extension-verify");

    var smoke = try runCli(&.{ "zova", "extension", "verify", "--json", "--smoke", bundle_path });
    defer smoke.deinit();
    try std.testing.expectEqual(@as(u8, 0), smoke.code);

    var trusted_before = try runCli(&.{ "zova", "extension", "trusted", "--json" });
    defer trusted_before.deinit();
    try std.testing.expectEqual(@as(u8, 0), trusted_before.code);
    try std.testing.expect(std.mem.indexOf(u8, trusted_before.stdout, "sample_ext") == null);

    var trust = try runCli(&.{ "zova", "extension", "trust", "--json", bundle_path });
    defer trust.deinit();
    try std.testing.expectEqual(@as(u8, 0), trust.code);

    var db_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&db_buffer, tmp.sub_path[0..], "builder-extension.zova");
    {
        var db = try zova.Database.create(db_path);
        defer db.deinit();
    }

    var install = try runCli(&.{ "zova", "--extension", bundle_path, "extension", "install", "--json", db_path, "sample_ext" });
    defer install.deinit();
    try std.testing.expectEqual(@as(u8, 0), install.code);

    var check = try runCli(&.{ "zova", "--extension", bundle_path, "extension", "check", "--json", db_path, "sample_ext" });
    defer check.deinit();
    try std.testing.expectEqual(@as(u8, 0), check.code);

    var source_deep_without_extension = try runCli(&.{ "zova", "check", "--json", "--deep", db_path });
    defer source_deep_without_extension.deinit();
    try std.testing.expectEqual(@as(u8, 4), source_deep_without_extension.code);
    try expectContains(source_deep_without_extension.stderr, "ExtensionUnavailable");
    try std.testing.expect(std.mem.indexOf(u8, source_deep_without_extension.stderr, bundle_path) == null);
    try std.testing.expect(std.mem.indexOf(u8, source_deep_without_extension.stderr, "create table") == null);

    var source_deep = try runCli(&.{ "zova", "--extension", bundle_path, "check", "--json", "--deep", db_path });
    defer source_deep.deinit();
    try std.testing.expectEqual(@as(u8, 0), source_deep.code);

    var backup = try runCli(&.{ "zova", "--extension", bundle_path, "backup", "--json", db_path, backup_path });
    defer backup.deinit();
    try std.testing.expectEqual(@as(u8, 0), backup.code);
    var backup_json = try parseJson(backup.stdout);
    defer backup_json.deinit();
    try expectJsonString(backup_json.value.object, "command", "backup");
    try expectJsonBool(backup_json.value.object, "verified", true);

    var compact = try runCli(&.{ "zova", "--extension", bundle_path, "compact", "--json", db_path, compact_path });
    defer compact.deinit();
    try std.testing.expectEqual(@as(u8, 0), compact.code);
    var compact_json = try parseJson(compact.stdout);
    defer compact_json.deinit();
    try expectJsonString(compact_json.value.object, "command", "compact");
    try expectJsonBool(compact_json.value.object, "verified", true);

    var restore = try runCli(&.{ "zova", "--extension", bundle_path, "restore", "--json", backup_path, restored_path });
    defer restore.deinit();
    try std.testing.expectEqual(@as(u8, 0), restore.code);
    var restore_json = try parseJson(restore.stdout);
    defer restore_json.deinit();
    try expectJsonString(restore_json.value.object, "command", "restore");
    try expectJsonBool(restore_json.value.object, "verified", true);

    for ([_][:0]const u8{ backup_path, compact_path, restored_path }) |copy_path| {
        var list = try runCli(&.{ "zova", "extension", "list", "--json", copy_path });
        defer list.deinit();
        try std.testing.expectEqual(@as(u8, 0), list.code);
        try expectContains(list.stdout, "\"name\": \"sample_ext\"");

        var copy_without_extension = try runCli(&.{ "zova", "check", "--json", "--deep", copy_path });
        defer copy_without_extension.deinit();
        try std.testing.expectEqual(@as(u8, 4), copy_without_extension.code);
        try expectContains(copy_without_extension.stderr, "ExtensionUnavailable");
        try std.testing.expect(std.mem.indexOf(u8, copy_without_extension.stderr, bundle_path) == null);
        try std.testing.expect(std.mem.indexOf(u8, copy_without_extension.stderr, "create table") == null);

        var copy_with_extension = try runCli(&.{ "zova", "--extension", bundle_path, "check", "--json", "--deep", copy_path });
        defer copy_with_extension.deinit();
        try std.testing.expectEqual(@as(u8, 0), copy_with_extension.code);

        var copy_extension_check = try runCli(&.{ "zova", "--extension", bundle_path, "extension", "check", "--json", copy_path, "sample_ext" });
        defer copy_extension_check.deinit();
        try std.testing.expectEqual(@as(u8, 0), copy_extension_check.code);
    }
}

test "cli extension verify smoke runs install and check hooks" {
    if (comptime !zova.extension_dynamic.supports_dynamic_loading) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var extension_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const extension_dir = try std.fmt.bufPrint(&extension_dir_buffer, ".zig-cache/tmp/{s}/smoke_marker_ext", .{tmp.sub_path});
    var bundle_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const bundle_path = try std.fmt.bufPrint(&bundle_buffer, ".zig-cache/tmp/{s}/smoke_marker_ext.zovaext", .{tmp.sub_path});
    var marker_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const marker_path = try std.fmt.bufPrint(&marker_buffer, ".zig-cache/tmp/{s}/smoke-marker.txt", .{tmp.sub_path});

    var scaffold = try runCli(&.{ "zova", "extension", "scaffold", "--json", extension_dir, "--name", "smoke_marker_ext", "--version", "0.1.0" });
    defer scaffold.deinit();
    try std.testing.expectEqual(@as(u8, 0), scaffold.code);

    const source_path = try std.fs.path.join(std.testing.allocator, &.{ extension_dir, "extension.zig" });
    defer std.testing.allocator.free(source_path);
    const source = try markerExtensionSource(marker_path);
    defer std.testing.allocator.free(source);
    try std.Io.Dir.cwd().writeFile(defaultIo(), .{ .sub_path = source_path, .data = source });

    var build = try runCli(&.{ "zova", "extension", "build", "--json", extension_dir });
    defer build.deinit();
    try std.testing.expectEqual(@as(u8, 0), build.code);

    var pack = try runCli(&.{ "zova", "extension", "pack", "--json", extension_dir, "--out", bundle_path });
    defer pack.deinit();
    try std.testing.expectEqual(@as(u8, 0), pack.code);

    var verify = try runCli(&.{ "zova", "extension", "verify", "--json", bundle_path });
    defer verify.deinit();
    try std.testing.expectEqual(@as(u8, 0), verify.code);
    try expectPathMissing(marker_path);

    var smoke = try runCli(&.{ "zova", "extension", "verify", "--json", "--smoke", bundle_path });
    defer smoke.deinit();
    try expectCliCode(&smoke, 0);
    try expectFileExists(std.Io.Dir.cwd(), marker_path);
}

test "cli extension verify smoke uses os temp directory" {
    if (comptime !zova.extension_dynamic.supports_dynamic_loading) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var extension_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const extension_dir = try std.fmt.bufPrint(&extension_dir_buffer, ".zig-cache/tmp/{s}/smoke_temp_ext", .{tmp.sub_path});
    var bundle_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const bundle_path = try std.fmt.bufPrint(&bundle_buffer, ".zig-cache/tmp/{s}/smoke_temp_ext.zovaext", .{tmp.sub_path});
    var marker_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const marker_path = try std.fmt.bufPrint(&marker_buffer, ".zig-cache/tmp/{s}/smoke-temp-marker.txt", .{tmp.sub_path});
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const smoke_cwd = try std.fmt.bufPrint(&cwd_buffer, ".zig-cache/tmp/{s}/smoke-cwd", .{tmp.sub_path});

    const absolute_marker_path = try absolutePathAlloc(marker_path);
    defer std.testing.allocator.free(absolute_marker_path);
    const absolute_bundle_path = try absolutePathAlloc(bundle_path);
    defer std.testing.allocator.free(absolute_bundle_path);

    var scaffold = try runCli(&.{ "zova", "extension", "scaffold", "--json", extension_dir, "--name", "smoke_temp_ext", "--version", "0.1.0" });
    defer scaffold.deinit();
    try std.testing.expectEqual(@as(u8, 0), scaffold.code);

    const source_path = try std.fs.path.join(std.testing.allocator, &.{ extension_dir, "extension.zig" });
    defer std.testing.allocator.free(source_path);
    const source = try markerExtensionSourceFor("smoke_temp_ext", absolute_marker_path);
    defer std.testing.allocator.free(source);
    try std.Io.Dir.cwd().writeFile(defaultIo(), .{ .sub_path = source_path, .data = source });

    var build = try runCli(&.{ "zova", "extension", "build", "--json", extension_dir });
    defer build.deinit();
    try std.testing.expectEqual(@as(u8, 0), build.code);

    var pack = try runCli(&.{ "zova", "extension", "pack", "--json", extension_dir, "--out", bundle_path });
    defer pack.deinit();
    try std.testing.expectEqual(@as(u8, 0), pack.code);

    try std.Io.Dir.cwd().createDirPath(defaultIo(), smoke_cwd);
    var smoke = try runCliProcessInCwd(&.{ "zova", "extension", "verify", "--json", "--smoke", absolute_bundle_path }, smoke_cwd);
    defer smoke.deinit();
    try expectCliCode(&smoke, 0);

    var smoke_cache_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const smoke_cache_path = try std.fmt.bufPrint(&smoke_cache_buffer, "{s}/.zig-cache", .{smoke_cwd});
    try expectPathMissing(smoke_cache_path);
}

test "cli extension verify smoke contains hook errors in child process" {
    if (comptime !zova.extension_dynamic.supports_dynamic_loading) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var extension_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const extension_dir = try std.fmt.bufPrint(&extension_dir_buffer, ".zig-cache/tmp/{s}/smoke_bad_ext", .{tmp.sub_path});
    var bundle_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const bundle_path = try std.fmt.bufPrint(&bundle_buffer, ".zig-cache/tmp/{s}/smoke_bad_ext.zovaext", .{tmp.sub_path});

    var scaffold = try runCli(&.{ "zova", "extension", "scaffold", "--json", extension_dir, "--name", "smoke_bad_ext", "--version", "0.1.0" });
    defer scaffold.deinit();
    try std.testing.expectEqual(@as(u8, 0), scaffold.code);

    const source_path = try std.fs.path.join(std.testing.allocator, &.{ extension_dir, "extension.zig" });
    defer std.testing.allocator.free(source_path);
    try std.Io.Dir.cwd().writeFile(defaultIo(), .{ .sub_path = source_path, .data = failingCheckExtensionSource() });

    var build = try runCli(&.{ "zova", "extension", "build", "--json", extension_dir });
    defer build.deinit();
    try std.testing.expectEqual(@as(u8, 0), build.code);

    var pack = try runCli(&.{ "zova", "extension", "pack", "--json", extension_dir, "--out", bundle_path });
    defer pack.deinit();
    try std.testing.expectEqual(@as(u8, 0), pack.code);

    var verify = try runCli(&.{ "zova", "extension", "verify", "--json", bundle_path });
    defer verify.deinit();
    try std.testing.expectEqual(@as(u8, 0), verify.code);

    var smoke = try runCli(&.{ "zova", "extension", "verify", "--json", "--smoke", bundle_path });
    defer smoke.deinit();
    try std.testing.expectEqual(@as(u8, 4), smoke.code);
    try expectContains(smoke.stderr, "extension-verify");
    try expectContains(smoke.stderr, "extension failed");
    try expectContains(smoke.stderr, "extension smoke child failed");
    try expectContains(smoke.stderr, "child stderr");
    try expectContains(smoke.stderr, "ExtensionInvalid");
}

test "cli extension verify rejects broken bundle artifacts" {
    if (comptime !zova.extension_dynamic.supports_dynamic_loading) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = defaultIo();

    const library_bytes = try std.Io.Dir.cwd().readFileAlloc(io, cli.dynamic_extension_library_path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(library_bytes);

    try tmp.dir.createDir(io, "missing_lib.zovaext", .default_dir);
    try tmp.dir.writeFile(io, .{
        .sub_path = "missing_lib.zovaext/extension.json",
        .data =
        \\{
        \\  "name": "dyn_test",
        \\  "version": "0.1.0",
        \\  "storage_prefix": "_zova_ext_dyn_test_",
        \\  "zova_abi_min": "0.21.0",
        \\  "capabilities": "sql,dynamic-test",
        \\  "library": "libmissing"
        \\}
        ,
    });

    try tmp.dir.createDir(io, "empty_lib.zovaext", .default_dir);
    try tmp.dir.writeFile(io, .{
        .sub_path = "empty_lib.zovaext/extension.json",
        .data =
        \\{
        \\  "name": "dyn_test",
        \\  "version": "0.1.0",
        \\  "storage_prefix": "_zova_ext_dyn_test_",
        \\  "zova_abi_min": "0.21.0",
        \\  "capabilities": "sql,dynamic-test",
        \\  "library": "libdyn_test"
        \\}
        ,
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "empty_lib.zovaext/libdyn_test", .data = "" });

    try tmp.dir.createDir(io, "missing_entrypoint.zovaext", .default_dir);
    try tmp.dir.writeFile(io, .{
        .sub_path = "missing_entrypoint.zovaext/extension.json",
        .data =
        \\{
        \\  "name": "dyn_test",
        \\  "version": "0.1.0",
        \\  "storage_prefix": "_zova_ext_dyn_test_",
        \\  "zova_abi_min": "0.21.0",
        \\  "capabilities": "sql,dynamic-test",
        \\  "library": "libdyn_test",
        \\  "entrypoint": "zova_missing_entry"
        \\}
        ,
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "missing_entrypoint.zovaext/libdyn_test", .data = library_bytes });

    var missing_lib_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing_lib_path = try std.fmt.bufPrint(&missing_lib_buffer, ".zig-cache/tmp/{s}/missing_lib.zovaext", .{tmp.sub_path});
    var empty_lib_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const empty_lib_path = try std.fmt.bufPrint(&empty_lib_buffer, ".zig-cache/tmp/{s}/empty_lib.zovaext", .{tmp.sub_path});
    var missing_entrypoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing_entrypoint_path = try std.fmt.bufPrint(&missing_entrypoint_buffer, ".zig-cache/tmp/{s}/missing_entrypoint.zovaext", .{tmp.sub_path});

    for ([_][]const u8{ missing_lib_path, empty_lib_path, missing_entrypoint_path }) |bundle_path| {
        var verify = try runCli(&.{ "zova", "extension", "verify", "--json", "--smoke", bundle_path });
        defer verify.deinit();
        try std.testing.expectEqual(@as(u8, 4), verify.code);
        try std.testing.expect(std.mem.indexOf(u8, verify.stderr, "ExtensionInvalid") != null or
            std.mem.indexOf(u8, verify.stderr, "ExtensionLoadFailed") != null or
            std.mem.indexOf(u8, verify.stderr, "FileNotFound") != null);
    }
}

test "cli extension pack rejects broken source artifacts and removes bundle output" {
    if (comptime !zova.extension_dynamic.supports_dynamic_loading) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = defaultIo();

    const library_bytes = try std.Io.Dir.cwd().readFileAlloc(io, cli.dynamic_extension_library_path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(library_bytes);

    const cases = [_]struct {
        dir_name: []const u8,
        library: []const u8,
        entrypoint: ?[]const u8 = null,
        library_bytes: ?[]const u8 = null,
    }{
        .{ .dir_name = "pack_missing_lib", .library = "libmissing" },
        .{ .dir_name = "pack_empty_lib", .library = "libdyn_test", .library_bytes = "" },
        .{ .dir_name = "pack_missing_entrypoint", .library = "libdyn_test", .entrypoint = "zova_missing_entry", .library_bytes = library_bytes },
    };

    for (cases) |case| {
        try tmp.dir.createDir(io, case.dir_name, .default_dir);
        const manifest_sub_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ case.dir_name, zova.extension_dynamic.bundle_manifest_file });
        defer std.testing.allocator.free(manifest_sub_path);
        const manifest = try testBuilderManifest("dyn_test", "0.1.0", "_zova_ext_dyn_test_", "sql,dynamic-test", case.library, case.entrypoint);
        defer std.testing.allocator.free(manifest);
        try tmp.dir.writeFile(io, .{ .sub_path = manifest_sub_path, .data = manifest });
        if (case.library_bytes) |bytes| {
            const library_sub_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ case.dir_name, case.library });
            defer std.testing.allocator.free(library_sub_path);
            try tmp.dir.writeFile(io, .{ .sub_path = library_sub_path, .data = bytes });
        }

        var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const dir_path = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, case.dir_name });
        var bundle_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const bundle_path = try std.fmt.bufPrint(&bundle_buffer, ".zig-cache/tmp/{s}/{s}.zovaext", .{ tmp.sub_path, case.dir_name });

        var pack = try runCli(&.{ "zova", "extension", "pack", "--json", dir_path, "--out", bundle_path });
        defer pack.deinit();
        try std.testing.expectEqual(@as(u8, 4), pack.code);
        try std.testing.expect(std.mem.indexOf(u8, pack.stderr, "ExtensionInvalid") != null or
            std.mem.indexOf(u8, pack.stderr, "ExtensionLoadFailed") != null or
            std.mem.indexOf(u8, pack.stderr, "FileNotFound") != null);
        try expectPathMissing(bundle_path);
    }
}

test "cli extension build produces symbol-bearing bundle artifact" {
    if (comptime !zova.extension_dynamic.supports_dynamic_loading) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var extension_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const extension_dir = try std.fmt.bufPrint(&extension_dir_buffer, ".zig-cache/tmp/{s}/artifact_ext", .{tmp.sub_path});
    var bundle_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const bundle_path = try std.fmt.bufPrint(&bundle_buffer, ".zig-cache/tmp/{s}/artifact_ext.zovaext", .{tmp.sub_path});

    var scaffold = try runCli(&.{ "zova", "extension", "scaffold", "--json", extension_dir, "--name", "artifact_ext", "--version", "0.1.0" });
    defer scaffold.deinit();
    try std.testing.expectEqual(@as(u8, 0), scaffold.code);

    var build = try runCli(&.{ "zova", "extension", "build", "--json", extension_dir });
    defer build.deinit();
    try std.testing.expectEqual(@as(u8, 0), build.code);

    const library_name = try testDynamicLibraryFileName("artifact_ext");
    defer std.testing.allocator.free(library_name);
    const library_path = try std.fs.path.join(std.testing.allocator, &.{ extension_dir, library_name });
    defer std.testing.allocator.free(library_path);
    try expectArtifactHasSymbol(library_path, "zova_extension_entry");

    var pack = try runCli(&.{ "zova", "extension", "pack", "--json", extension_dir, "--out", bundle_path });
    defer pack.deinit();
    try std.testing.expectEqual(@as(u8, 0), pack.code);

    var verify = try runCli(&.{ "zova", "extension", "verify", "--json", "--smoke", bundle_path });
    defer verify.deinit();
    try std.testing.expectEqual(@as(u8, 0), verify.code);
}

test "downstream bridge object and static artifacts expose extension entrypoint" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = defaultIo();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrint(&source_buffer, ".zig-cache/tmp/{s}/bridge_artifact_extension.zig", .{tmp.sub_path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = simpleArtifactExtensionSource() });

    var object_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const object_path = try std.fmt.bufPrint(&object_buffer, ".zig-cache/tmp/{s}/bridge_artifact_extension.o", .{tmp.sub_path});
    var object_cache_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const object_cache = try std.fmt.bufPrint(&object_cache_buffer, ".zig-cache/tmp/{s}/object-cache", .{tmp.sub_path});
    var object_global_cache_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const object_global_cache = try std.fmt.bufPrint(&object_global_cache_buffer, ".zig-cache/tmp/{s}/object-global-cache", .{tmp.sub_path});
    var object_result = try runZigBridgeArtifactCommand("build-obj", source_path, object_path, object_cache, object_global_cache);
    defer object_result.deinit();
    try std.testing.expectEqual(@as(u8, 0), object_result.code);
    try expectArtifactHasSymbol(object_path, "zova_extension_entry");

    var archive_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const archive_path = try std.fmt.bufPrint(&archive_buffer, ".zig-cache/tmp/{s}/libbridge_artifact_extension.a", .{tmp.sub_path});
    var archive_cache_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const archive_cache = try std.fmt.bufPrint(&archive_cache_buffer, ".zig-cache/tmp/{s}/archive-cache", .{tmp.sub_path});
    var archive_global_cache_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const archive_global_cache = try std.fmt.bufPrint(&archive_global_cache_buffer, ".zig-cache/tmp/{s}/archive-global-cache", .{tmp.sub_path});
    var archive_result = try runZigBridgeArtifactCommand("build-lib-static", source_path, archive_path, archive_cache, archive_global_cache);
    defer archive_result.deinit();
    if (archive_result.code == 0) {
        try expectArtifactHasSymbol(archive_path, "zova_extension_entry");
    } else {
        try std.testing.expect(archive_result.stderr.len != 0 or archive_result.stdout.len != 0);
    }
}

test "cli extension list info and diagnostics inspect unavailable extension metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "extension-unavailable.zova");
    try createUnavailableExtensionFixture(db_path);

    var list = try runCli(&.{ "zova", "extension", "list", "--json", db_path });
    defer list.deinit();
    try std.testing.expectEqual(@as(u8, 0), list.code);
    var list_json = try parseJson(list.stdout);
    defer list_json.deinit();
    try expectJsonArrayLen(list_json.value.object, "extensions", 1);

    var info = try runCli(&.{ "zova", "extension", "info", "--json", db_path, "test" });
    defer info.deinit();
    try std.testing.expectEqual(@as(u8, 0), info.code);
    var info_json = try parseJson(info.stdout);
    defer info_json.deinit();
    try expectJsonString(info_json.value.object, "command", "extension-info");
    const extension_value = info_json.value.object.get("extension") orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.object, std.meta.activeTag(extension_value));
    try expectJsonString(extension_value.object, "name", "test");

    var check_extension = try runCli(&.{ "zova", "extension", "check", "--json", db_path, "test" });
    defer check_extension.deinit();
    try std.testing.expectEqual(@as(u8, 4), check_extension.code);
    try expectContains(check_extension.stderr, "ExtensionUnavailable");

    var doctor = try runCli(&.{ "zova", "doctor", "--json", db_path });
    defer doctor.deinit();
    try std.testing.expectEqual(@as(u8, 4), doctor.code);
    var doctor_json = try parseJson(doctor.stderr);
    defer doctor_json.deinit();
    try expectJsonObjectHasInt(doctor_json.value.object, "issue_counts", "extension");
    try expectContains(doctor.stderr, "ExtensionUnavailable");

    var check = try runCli(&.{ "zova", "check", "--json", "--deep", db_path });
    defer check.deinit();
    try std.testing.expectEqual(@as(u8, 4), check.code);
    var check_json = try parseJson(check.stderr);
    defer check_json.deinit();
    try expectJsonObjectHasInt(check_json.value.object, "issue_counts", "extension");
    try expectContains(check.stderr, "ExtensionUnavailable");
}

test "cli diagnostics report unknown extension private storage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "extension-orphan-storage.zova");

    {
        var db = try zova.Database.create(db_path);
        defer db.deinit();
    }
    {
        var raw = try zova.sqlite.Database.open(db_path);
        defer raw.deinit();
        try raw.exec("create table _zova_ext_orphan_meta (key text primary key, value text not null)");
    }

    var doctor = try runCli(&.{ "zova", "doctor", "--json", db_path });
    defer doctor.deinit();
    try std.testing.expectEqual(@as(u8, 4), doctor.code);
    try expectContains(doctor.stderr, "unknown_extension_storage");
    try expectContains(doctor.stderr, "_zova_ext_orphan_meta");
    try std.testing.expect(std.mem.indexOf(u8, doctor.stderr, "create table") == null);

    var check = try runCli(&.{ "zova", "check", "--json", "--deep", db_path });
    defer check.deinit();
    try std.testing.expectEqual(@as(u8, 4), check.code);
    try expectContains(check.stderr, "unknown_extension_storage");
}

test "cli extension diagnostics keep trgm indexed text private" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "trgm-private-diagnostics.zova");
    const sensitive_text = "secret recovery phrase midnight sunflower invoice";

    {
        var db = try zova.Database.create(db_path);
        defer db.deinit();
        try db.installExtension("trgm");
        try db.exec("select zova_trgm_create_index('docs')");
        var put = try db.prepare("select zova_trgm_put('docs', 'doc:secret', 'record', 'messages', '1', ?)");
        defer put.deinit();
        try put.bindText(1, sensitive_text);
        try std.testing.expectEqual(zova.sqlite.Step.row, try put.step());
    }
    {
        var raw = try zova.sqlite.Database.open(db_path);
        defer raw.deinit();
        try raw.exec("delete from _zova_ext_trgm_terms");
    }

    var extension_check = try runCli(&.{ "zova", "extension", "check", "--json", db_path, "trgm" });
    defer extension_check.deinit();
    try std.testing.expectEqual(@as(u8, 4), extension_check.code);
    try expectContains(extension_check.stderr, "ExtensionInvalid");
    try std.testing.expect(std.mem.indexOf(u8, extension_check.stderr, sensitive_text) == null);
    try std.testing.expect(std.mem.indexOf(u8, extension_check.stderr, "create table") == null);

    var doctor = try runCli(&.{ "zova", "doctor", "--json", "--limit", "1", db_path });
    defer doctor.deinit();
    try std.testing.expectEqual(@as(u8, 4), doctor.code);
    var doctor_json = try parseJson(doctor.stderr);
    defer doctor_json.deinit();
    try expectJsonObjectHasInt(doctor_json.value.object, "issue_counts", "extension");
    try expectContains(doctor.stderr, "trgm_check_failed");
    try expectContains(doctor.stderr, "zova extension check");
    try std.testing.expect(std.mem.indexOf(u8, doctor.stderr, sensitive_text) == null);
    try std.testing.expect(std.mem.indexOf(u8, doctor.stderr, "create table") == null);

    var bounded = try runCli(&.{ "zova", "doctor", "--json", "--limit", "0", db_path });
    defer bounded.deinit();
    try std.testing.expectEqual(@as(u8, 4), bounded.code);
    var bounded_json = try parseJson(bounded.stderr);
    defer bounded_json.deinit();
    try expectJsonArrayLen(bounded_json.value.object, "issues", 0);
    try expectJsonObjectHasInt(bounded_json.value.object, "issue_counts", "extension");

    var check = try runCli(&.{ "zova", "check", "--json", "--deep", db_path });
    defer check.deinit();
    try std.testing.expectEqual(@as(u8, 4), check.code);
    var check_json = try parseJson(check.stderr);
    defer check_json.deinit();
    try expectJsonObjectHasInt(check_json.value.object, "issue_counts", "extension");
    try expectContains(check.stderr, "trgm_check_failed");
    try std.testing.expect(std.mem.indexOf(u8, check.stderr, sensitive_text) == null);
    try std.testing.expect(std.mem.indexOf(u8, check.stderr, "create table") == null);
}

test "cli graph commands inspect graphs nodes neighbors and walks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graphs.zova");

    {
        var db = try zova.Database.create(db_path);
        defer db.deinit();

        try db.createGraph("app");
        try db.putGraphNode(.{ .graph_name = "app", .node_id = "message:1", .kind = "message", .target_type = .record, .target_ref = "messages:1" });
        try db.putGraphNode(.{ .graph_name = "app", .node_id = "object:1", .kind = "attachment", .target_type = .external, .target_ref = "object:1" });
        try db.putGraphNode(.{ .graph_name = "app", .node_id = "message:2", .kind = "message", .target_type = .record, .target_ref = "messages:2" });
        try db.putGraphEdge(.{ .graph_name = "app", .from_node_id = "message:1", .edge_type = "has_attachment", .to_node_id = "object:1" });
        try db.putGraphEdge(.{ .graph_name = "app", .from_node_id = "message:1", .edge_type = "replies_to", .to_node_id = "message:2" });
    }

    var graphs = try runCli(&.{ "zova", "graphs", "--json", db_path });
    defer graphs.deinit();
    try std.testing.expectEqual(@as(u8, 0), graphs.code);
    var graphs_json = try parseJson(graphs.stdout);
    defer graphs_json.deinit();
    try expectJsonString(graphs_json.value.object, "command", "graphs");
    try expectJsonArrayLen(graphs_json.value.object, "graphs", 1);

    var graph = try runCli(&.{ "zova", "graph", db_path, "app" });
    defer graph.deinit();
    try std.testing.expectEqual(@as(u8, 0), graph.code);
    try expectContains(graph.stdout, "graph: app");
    try expectContains(graph.stdout, "nodes: 3");
    try expectContains(graph.stdout, "edges: 2");

    var node = try runCli(&.{ "zova", "graph-node", "--json", db_path, "app", "message:1" });
    defer node.deinit();
    try std.testing.expectEqual(@as(u8, 0), node.code);
    var node_json = try parseJson(node.stdout);
    defer node_json.deinit();
    try expectJsonString(node_json.value.object, "command", "graph-node");
    try expectJsonString(node_json.value.object, "node_id", "message:1");
    try expectJsonString(node_json.value.object, "kind", "message");

    var neighbors = try runCli(&.{ "zova", "graph-neighbors", "--json", "--limit", "1", db_path, "app", "message:1" });
    defer neighbors.deinit();
    try std.testing.expectEqual(@as(u8, 0), neighbors.code);
    var neighbors_json = try parseJson(neighbors.stdout);
    defer neighbors_json.deinit();
    try expectJsonString(neighbors_json.value.object, "command", "graph-neighbors");
    try expectJsonArrayLen(neighbors_json.value.object, "neighbors", 1);
    try expectJsonBool(neighbors_json.value.object, "truncated", true);

    var walk = try runCli(&.{ "zova", "graph-walk", "--json", "--max-depth", "2", db_path, "app", "message:1" });
    defer walk.deinit();
    try std.testing.expectEqual(@as(u8, 0), walk.code);
    var walk_json = try parseJson(walk.stdout);
    defer walk_json.deinit();
    try expectJsonString(walk_json.value.object, "command", "graph-walk");
    try expectJsonArrayLen(walk_json.value.object, "nodes", 3);
}

test "cli graph usage errors and diagnostics are bounded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-diagnostic.zova");

    {
        var db = try zova.Database.create(db_path);
        defer db.deinit();
        try db.createGraph("app");
        try db.putGraphNode(.{ .graph_name = "app", .node_id = "message:1", .kind = "message" });
    }

    var invalid = try runCli(&.{ "zova", "graph-neighbors", "--limit", "101", db_path, "app", "message:1" });
    defer invalid.deinit();
    try std.testing.expectEqual(@as(u8, 2), invalid.code);

    {
        var raw = try zova.sqlite.Database.open(db_path);
        defer raw.deinit();
        try raw.exec(
            \\insert into _zova_graph_edge_types(graph_key,name)
            \\select graph_key,'mentions' from _zova_graphs where name='app';
            \\insert into _zova_graph_edges (graph_key, from_node_key, edge_type_key, to_node_key, created_order)
            \\select g.graph_key, n.node_key, et.edge_type_key, 999999, 1
            \\from _zova_graphs g join _zova_graph_nodes n on n.graph_key = g.graph_key
            \\join _zova_graph_edge_types et on et.graph_key=g.graph_key and et.name='mentions'
            \\where g.name = 'app' and n.node_id = 'message:1'
        );
    }

    var doctor = try runCli(&.{ "zova", "doctor", "--json", "--limit", "1", db_path });
    defer doctor.deinit();
    try std.testing.expectEqual(@as(u8, 4), doctor.code);
    var doctor_json = try parseJson(doctor.stderr);
    defer doctor_json.deinit();
    try expectJsonString(doctor_json.value.object, "command", "doctor");
    try expectJsonObjectHasInt(doctor_json.value.object, "issue_counts", "graph");
    try expectJsonArrayLen(doctor_json.value.object, "issues", 1);
    try std.testing.expect(std.mem.indexOf(u8, doctor.stderr, "_zova_graph_edges") == null);
    try std.testing.expect(std.mem.indexOf(u8, doctor.stderr, "hidden chunk bytes") == null);

    var check = try runCli(&.{ "zova", "check", "--json", "--deep", db_path });
    defer check.deinit();
    try std.testing.expectEqual(@as(u8, 4), check.code);
    var check_json = try parseJson(check.stderr);
    defer check_json.deinit();
    try expectJsonObjectHasInt(check_json.value.object, "issue_counts", "graph");
}

test "cli object-store commands create bind inspect replace and unbind" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "object-store-main.zova");

    var store_one_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_one_path = try testingDbPath(&store_one_buffer, tmp.sub_path[0..], "object-store-one.zova");

    var store_two_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_two_path = try testingDbPath(&store_two_buffer, tmp.sub_path[0..], "object-store-two.zova");

    {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
    }

    var create_one = try runCli(&.{ "zova", "object-store", "create", "--json", store_one_path });
    defer create_one.deinit();
    try std.testing.expectEqual(@as(u8, 0), create_one.code);
    var create_one_json = try parseJson(create_one.stdout);
    defer create_one_json.deinit();
    try expectJsonString(create_one_json.value.object, "command", "object-store-create");
    try expectJsonBool(create_one_json.value.object, "created", true);

    var create_two = try runCli(&.{ "zova", "object-store", "create", store_two_path });
    defer create_two.deinit();
    try std.testing.expectEqual(@as(u8, 0), create_two.code);
    try expectContains(create_two.stdout, "object-store-create: ok");

    var bind = try runCli(&.{ "zova", "object-store", "bind", "--json", main_path, store_one_path });
    defer bind.deinit();
    try std.testing.expectEqual(@as(u8, 0), bind.code);
    var bind_json = try parseJson(bind.stdout);
    defer bind_json.deinit();
    try expectJsonString(bind_json.value.object, "command", "object-store-bind");
    try expectJsonBool(bind_json.value.object, "bound", true);

    {
        var db = try zova.Database.open(main_path);
        defer db.deinit();
        _ = try db.putObject("stored in first bound store");
        try std.testing.expectEqual(@as(i64, 0), try countRawRows(&db.sqlite_db, "select count(*) from _zova_objects"));
    }

    {
        var store = try zova.sqlite.Database.open(store_one_path);
        defer store.deinit();
        try std.testing.expectEqual(@as(i64, 1), try countRawRows(&store, "select count(*) from _zova_objects"));
    }

    var info = try runCli(&.{ "zova", "object-store", "info", "--json", main_path });
    defer info.deinit();
    try std.testing.expectEqual(@as(u8, 0), info.code);
    var info_json = try parseJson(info.stdout);
    defer info_json.deinit();
    try expectJsonString(info_json.value.object, "command", "object-store-info");
    try expectJsonBool(info_json.value.object, "bound", true);
    try expectJsonString(info_json.value.object, "path", store_one_path);

    var replace_bind = try runCli(&.{ "zova", "object-store", "bind", "--json", main_path, store_two_path });
    defer replace_bind.deinit();
    try std.testing.expectEqual(@as(u8, 0), replace_bind.code);
    var replace_bind_json = try parseJson(replace_bind.stdout);
    defer replace_bind_json.deinit();
    try expectJsonString(replace_bind_json.value.object, "command", "object-store-bind");
    try expectJsonString(replace_bind_json.value.object, "path", store_two_path);

    {
        var db = try zova.Database.open(main_path);
        defer db.deinit();
        _ = try db.putObject("stored in second bound store");
    }

    {
        var store = try zova.sqlite.Database.open(store_two_path);
        defer store.deinit();
        try std.testing.expectEqual(@as(i64, 1), try countRawRows(&store, "select count(*) from _zova_objects"));
    }

    var unbind = try runCli(&.{ "zova", "object-store", "unbind", "--json", main_path });
    defer unbind.deinit();
    try std.testing.expectEqual(@as(u8, 0), unbind.code);
    var unbind_json = try parseJson(unbind.stdout);
    defer unbind_json.deinit();
    try expectJsonString(unbind_json.value.object, "command", "object-store-unbind");
    try expectJsonBool(unbind_json.value.object, "bound", false);

    var unbound_info = try runCli(&.{ "zova", "object-store", "info", main_path });
    defer unbound_info.deinit();
    try std.testing.expectEqual(@as(u8, 0), unbound_info.code);
    try expectContains(unbound_info.stdout, "bound: false");
}

test "cli object-store bind replaces when the previous store is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "object-store-bind-missing-main.zova");

    var old_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const old_store_path = try testingDbPath(&old_store_buffer, tmp.sub_path[0..], "object-store-bind-old.zova");

    var new_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const new_store_path = try testingDbPath(&new_store_buffer, tmp.sub_path[0..], "object-store-bind-new.zova");

    {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
        try zova.createObjectStore(old_store_path);
        try db.bindObjectStore(old_store_path);
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.deleteFile(io, "object-store-bind-old.zova");
    try zova.createObjectStore(new_store_path);

    var bind = try runCli(&.{ "zova", "object-store", "bind", "--json", main_path, new_store_path });
    defer bind.deinit();
    try std.testing.expectEqual(@as(u8, 0), bind.code);

    var bind_json = try parseJson(bind.stdout);
    defer bind_json.deinit();
    try expectJsonString(bind_json.value.object, "command", "object-store-bind");
    try expectJsonString(bind_json.value.object, "path", new_store_path);

    var db = try zova.Database.open(main_path);
    defer db.deinit();
    const id = try db.putObject("stored after missing-store bind");
    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "stored after missing-store bind", object.bytes);
}

test "cli vector-store commands create bind inspect replace and unbind" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "vector-store-main.zova");

    var store_one_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_one_path = try testingDbPath(&store_one_buffer, tmp.sub_path[0..], "vector-store-one.zova");

    var store_two_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_two_path = try testingDbPath(&store_two_buffer, tmp.sub_path[0..], "vector-store-two.zova");

    {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
    }

    var create_one = try runCli(&.{ "zova", "vector-store", "create", "--json", store_one_path });
    defer create_one.deinit();
    try std.testing.expectEqual(@as(u8, 0), create_one.code);
    var create_one_json = try parseJson(create_one.stdout);
    defer create_one_json.deinit();
    try expectJsonString(create_one_json.value.object, "command", "vector-store-create");
    try expectJsonBool(create_one_json.value.object, "created", true);

    var create_two = try runCli(&.{ "zova", "vector-store", "create", store_two_path });
    defer create_two.deinit();
    try std.testing.expectEqual(@as(u8, 0), create_two.code);
    try expectContains(create_two.stdout, "vector-store-create: ok");

    var bind = try runCli(&.{ "zova", "vector-store", "bind", "--json", main_path, store_one_path });
    defer bind.deinit();
    try std.testing.expectEqual(@as(u8, 0), bind.code);
    var bind_json = try parseJson(bind.stdout);
    defer bind_json.deinit();
    try expectJsonString(bind_json.value.object, "command", "vector-store-bind");
    try expectJsonBool(bind_json.value.object, "bound", true);

    {
        var db = try zova.Database.open(main_path);
        defer db.deinit();
        try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
        try db.putVector("docs", "v1", .{ .f32 = &.{ 1.0, 2.0 } });
        try std.testing.expectEqual(@as(i64, 0), try countRawRows(&db.sqlite_db, "select count(*) from _zova_vectors"));

        var results = try db.searchVectors(std.testing.allocator, "docs", .{ .f32 = &.{ 1.0, 2.0 } }, 1);
        defer results.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), results.items.len);
        try std.testing.expectEqualStrings("v1", results.items[0].id);
    }

    {
        var store = try zova.sqlite.Database.open(store_one_path);
        defer store.deinit();
        try std.testing.expectEqual(@as(i64, 1), try countRawRows(&store, "select count(*) from _zova_vectors"));
    }

    var info = try runCli(&.{ "zova", "vector-store", "info", "--json", main_path });
    defer info.deinit();
    try std.testing.expectEqual(@as(u8, 0), info.code);
    var info_json = try parseJson(info.stdout);
    defer info_json.deinit();
    try expectJsonString(info_json.value.object, "command", "vector-store-info");
    try expectJsonBool(info_json.value.object, "bound", true);
    try expectJsonString(info_json.value.object, "path", store_one_path);

    var replace_bind = try runCli(&.{ "zova", "vector-store", "bind", "--json", main_path, store_two_path });
    defer replace_bind.deinit();
    try std.testing.expectEqual(@as(u8, 0), replace_bind.code);
    var replace_bind_json = try parseJson(replace_bind.stdout);
    defer replace_bind_json.deinit();
    try expectJsonString(replace_bind_json.value.object, "command", "vector-store-bind");
    try expectJsonString(replace_bind_json.value.object, "path", store_two_path);

    {
        var db = try zova.Database.open(main_path);
        defer db.deinit();
        try db.createVectorCollection("images", .{ .dimensions = 2, .metric = .l2 });
        try db.putVector("images", "img-1", .{ .f32 = &.{ 3.0, 4.0 } });
    }

    {
        var store = try zova.sqlite.Database.open(store_two_path);
        defer store.deinit();
        try std.testing.expectEqual(@as(i64, 1), try countRawRows(&store, "select count(*) from _zova_vectors"));
    }

    var unbind = try runCli(&.{ "zova", "vector-store", "unbind", "--json", main_path });
    defer unbind.deinit();
    try std.testing.expectEqual(@as(u8, 0), unbind.code);
    var unbind_json = try parseJson(unbind.stdout);
    defer unbind_json.deinit();
    try expectJsonString(unbind_json.value.object, "command", "vector-store-unbind");
    try expectJsonBool(unbind_json.value.object, "bound", false);

    var unbound_info = try runCli(&.{ "zova", "vector-store", "info", main_path });
    defer unbound_info.deinit();
    try std.testing.expectEqual(@as(u8, 0), unbound_info.code);
    try expectContains(unbound_info.stdout, "bound: false");
}

test "cli split moves existing object and vector storage into bound stores" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var object_main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const object_main_path = try testingDbPath(&object_main_buffer, tmp.sub_path[0..], "split-object-main.zova");

    var object_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const object_store_path = try testingDbPath(&object_store_buffer, tmp.sub_path[0..], "split-object-store.zova");

    {
        var db = try zova.Database.create(object_main_path);
        defer db.deinit();
        try db.exec("create table documents (object_id blob not null, vector_id text not null, title text not null)");
        const object_id = try db.putObject("cli split object");
        const object_id_hex = try lowerHexAlloc(&object_id);
        defer std.testing.allocator.free(object_id_hex);
        try insertDocument(&db, object_id, "unused", "object metadata stays in main");
        try db.putObjectChunk(zova.objectChunkId("cli split loose chunk"), "cli split loose chunk");
        try db.createGraph("split_objects");
        try db.putGraphNode(.{ .graph_name = "split_objects", .node_id = "doc:object", .kind = "document", .target_type = .record, .target_namespace = "documents", .target_ref = "object metadata stays in main" });
        try db.putGraphNode(.{ .graph_name = "split_objects", .node_id = "object:primary", .kind = "object", .target_type = .object, .target_ref = object_id_hex });
        try db.putGraphEdge(.{ .graph_name = "split_objects", .from_node_id = "doc:object", .edge_type = "has_object", .to_node_id = "object:primary" });
    }

    var object_split = try runCli(&.{ "zova", "split", "--objects", "--json", object_main_path, object_store_path });
    defer object_split.deinit();
    try std.testing.expectEqual(@as(u8, 0), object_split.code);
    var object_json = try parseJson(object_split.stdout);
    defer object_json.deinit();
    const object_root = object_json.value.object;
    try expectJsonString(object_root, "command", "split");
    try expectJsonString(object_root, "role", "objects");
    try expectJsonString(object_root, "main_path", object_main_path);
    try expectJsonString(object_root, "store_path", object_store_path);
    try expectJsonBool(object_root, "created", true);
    try expectJsonBool(object_root, "bound", true);
    try expectJsonBool(object_root, "verified", true);
    try expectJsonObjectHasInt(object_root, "copied", "objects");
    try expectJsonObjectHasInt(object_root, "copied", "chunks");
    try expectJsonObjectHasInt(object_root, "copied", "manifest_rows");
    try expectJsonObjectHasInt(object_root, "cleared", "objects");

    {
        var db = try zova.Database.open(object_main_path);
        defer db.deinit();
        try std.testing.expectEqual(@as(i64, 0), try countRawRows(&db.sqlite_db, "select count(*) from _zova_objects"));
        try std.testing.expectEqual(@as(i64, 1), try countRawRows(&db.sqlite_db, "select count(*) from documents"));
        try std.testing.expect(try db.hasGraphEdge("split_objects", "doc:object", "has_object", "object:primary"));
    }
    {
        var store = try zova.sqlite.Database.open(object_store_path);
        defer store.deinit();
        try std.testing.expectEqual(@as(i64, 1), try countRawRows(&store, "select count(*) from _zova_objects"));
    }
    {
        var check = try runCli(&.{ "zova", "check", "--deep", "--json", object_main_path });
        defer check.deinit();
        try std.testing.expectEqual(@as(u8, 0), check.code);

        var doctor = try runCli(&.{ "zova", "doctor", "--json", object_main_path });
        defer doctor.deinit();
        try std.testing.expectEqual(@as(u8, 0), doctor.code);
    }

    var vector_main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const vector_main_path = try testingDbPath(&vector_main_buffer, tmp.sub_path[0..], "split-vector-main.zova");

    var vector_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const vector_store_path = try testingDbPath(&vector_store_buffer, tmp.sub_path[0..], "split-vector-store.zova");

    {
        var db = try zova.Database.create(vector_main_path);
        defer db.deinit();
        try db.exec("create table documents (vector_id text not null, title text not null)");
        try db.exec("insert into documents (vector_id, title) values ('doc-a', 'vector metadata stays in main')");
        try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
        try db.putVectors("docs", &.{
            .{ .id = "doc-a", .values = .{ .f32 = &.{ 1.0, 0.0 } } },
            .{ .id = "doc-b", .values = .{ .f32 = &.{ 0.0, 2.0 } } },
        });
        try db.createGraph("split_vectors");
        try db.putGraphNode(.{ .graph_name = "split_vectors", .node_id = "doc:a", .kind = "document", .target_type = .record, .target_namespace = "documents", .target_ref = "doc-a" });
        try db.putGraphNode(.{ .graph_name = "split_vectors", .node_id = "vector:doc-a", .kind = "embedding", .target_type = .vector, .target_namespace = "docs", .target_ref = "doc-a" });
        try db.putGraphEdge(.{ .graph_name = "split_vectors", .from_node_id = "doc:a", .edge_type = "embedded_as", .to_node_id = "vector:doc-a" });
    }

    var vector_split = try runCli(&.{ "zova", "split", "--vectors", "--json", vector_main_path, vector_store_path });
    defer vector_split.deinit();
    try std.testing.expectEqual(@as(u8, 0), vector_split.code);
    var vector_json = try parseJson(vector_split.stdout);
    defer vector_json.deinit();
    const vector_root = vector_json.value.object;
    try expectJsonString(vector_root, "command", "split");
    try expectJsonString(vector_root, "role", "vectors");
    try expectJsonString(vector_root, "main_path", vector_main_path);
    try expectJsonString(vector_root, "store_path", vector_store_path);
    try expectJsonBool(vector_root, "created", true);
    try expectJsonBool(vector_root, "bound", true);
    try expectJsonBool(vector_root, "verified", true);
    try expectJsonObjectHasInt(vector_root, "copied", "vector_collections");
    try expectJsonObjectHasInt(vector_root, "copied", "vectors");
    try expectJsonObjectHasInt(vector_root, "cleared", "vectors");

    {
        var db = try zova.Database.open(vector_main_path);
        defer db.deinit();
        try std.testing.expectEqual(@as(i64, 0), try countRawRows(&db.sqlite_db, "select count(*) from _zova_vectors"));
        try std.testing.expectEqual(@as(i64, 1), try countRawRows(&db.sqlite_db, "select count(*) from documents"));
        var results = try db.searchVectors(std.testing.allocator, "docs", .{ .f32 = &.{ 1.0, 0.0 } }, 1);
        defer results.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("doc-a", results.items[0].id);
        try std.testing.expect(try db.hasGraphEdge("split_vectors", "doc:a", "embedded_as", "vector:doc-a"));
    }
    {
        var check = try runCli(&.{ "zova", "check", "--deep", "--json", vector_main_path });
        defer check.deinit();
        try std.testing.expectEqual(@as(u8, 0), check.code);

        var doctor = try runCli(&.{ "zova", "doctor", "--json", vector_main_path });
        defer doctor.deinit();
        try std.testing.expectEqual(@as(u8, 0), doctor.code);
    }
}

test "cli bind rejects non-empty main storage and split usage errors are bounded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var object_main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const object_main_path = try testingDbPath(&object_main_buffer, tmp.sub_path[0..], "bind-reject-object-main.zova");

    var object_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const object_store_path = try testingDbPath(&object_store_buffer, tmp.sub_path[0..], "bind-reject-object-store.zova");

    {
        var db = try zova.Database.create(object_main_path);
        defer db.deinit();
        _ = try db.putObject("existing object requires split");
    }
    try zova.createObjectStore(object_store_path);

    var object_bind = try runCli(&.{ "zova", "object-store", "bind", object_main_path, object_store_path });
    defer object_bind.deinit();
    try std.testing.expectEqual(@as(u8, 3), object_bind.code);
    try expectContains(object_bind.stderr, "split --objects");

    var vector_main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const vector_main_path = try testingDbPath(&vector_main_buffer, tmp.sub_path[0..], "bind-reject-vector-main.zova");

    var vector_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const vector_store_path = try testingDbPath(&vector_store_buffer, tmp.sub_path[0..], "bind-reject-vector-store.zova");

    {
        var db = try zova.Database.create(vector_main_path);
        defer db.deinit();
        try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    }
    try zova.createVectorStore(vector_store_path);

    var vector_bind = try runCli(&.{ "zova", "vector-store", "bind", vector_main_path, vector_store_path });
    defer vector_bind.deinit();
    try std.testing.expectEqual(@as(u8, 3), vector_bind.code);
    try expectContains(vector_bind.stderr, "split --vectors");

    const usage_cases = [_][]const []const u8{
        &.{ "zova", "split", object_main_path, object_store_path },
        &.{ "zova", "split", "--objects", "--vectors", object_main_path, object_store_path },
        &.{ "zova", "split", "--objects", object_main_path },
        &.{ "zova", "split", "--objects", object_main_path, object_store_path, "extra" },
        &.{ "zova", "split", "--objects", object_main_path, object_main_path },
        &.{ "zova", "split", "--wat", object_main_path, object_store_path },
    };
    for (usage_cases) |case| {
        var result = try runCli(case);
        defer result.deinit();
        try std.testing.expectEqual(@as(u8, 2), result.code);
    }
}

test "cli graph-store commands create bind inspect repair and unbind" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "graph-store-main.zova");
    var store_one_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_one_path = try testingDbPath(&store_one_buffer, tmp.sub_path[0..], "graph-store-one.zova");
    var store_two_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_two_path = try testingDbPath(&store_two_buffer, tmp.sub_path[0..], "graph-store-two.zova");

    {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
    }

    var unbound_info = try runCli(&.{ "zova", "graph-store", "info", main_path });
    defer unbound_info.deinit();
    try std.testing.expectEqual(@as(u8, 0), unbound_info.code);
    try expectContains(unbound_info.stdout, "graph-store-info: ok");
    try expectContains(unbound_info.stdout, "bound: false");

    var create_one = try runCli(&.{ "zova", "graph-store", "create", "--json", store_one_path });
    defer create_one.deinit();
    try std.testing.expectEqual(@as(u8, 0), create_one.code);
    var create_json = try parseJson(create_one.stdout);
    defer create_json.deinit();
    try expectJsonString(create_json.value.object, "command", "graph-store-create");
    try expectJsonBool(create_json.value.object, "created", true);

    var bind = try runCli(&.{ "zova", "graph-store", "bind", "--json", main_path, store_one_path });
    defer bind.deinit();
    try std.testing.expectEqual(@as(u8, 0), bind.code);
    var bind_json = try parseJson(bind.stdout);
    defer bind_json.deinit();
    try expectJsonString(bind_json.value.object, "command", "graph-store-bind");
    try expectJsonString(bind_json.value.object, "path", store_one_path);
    try expectJsonBool(bind_json.value.object, "bound", true);

    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.deleteFile(io, "graph-store-one.zova");
    try zova.createGraphStore(store_two_path);

    var repair = try runCli(&.{ "zova", "graph-store", "bind", "--json", main_path, store_two_path });
    defer repair.deinit();
    try std.testing.expectEqual(@as(u8, 0), repair.code);
    var repair_json = try parseJson(repair.stdout);
    defer repair_json.deinit();
    try expectJsonString(repair_json.value.object, "path", store_two_path);

    var info = try runCli(&.{ "zova", "graph-store", "info", "--json", main_path });
    defer info.deinit();
    try std.testing.expectEqual(@as(u8, 0), info.code);
    var info_json = try parseJson(info.stdout);
    defer info_json.deinit();
    try expectJsonString(info_json.value.object, "command", "graph-store-info");
    try expectJsonString(info_json.value.object, "path", store_two_path);
    try expectJsonBool(info_json.value.object, "bound", true);

    var unbind = try runCli(&.{ "zova", "graph-store", "unbind", "--json", main_path });
    defer unbind.deinit();
    try std.testing.expectEqual(@as(u8, 0), unbind.code);
    var unbind_json = try parseJson(unbind.stdout);
    defer unbind_json.deinit();
    try expectJsonString(unbind_json.value.object, "command", "graph-store-unbind");
    try expectJsonBool(unbind_json.value.object, "bound", false);
}

test "cli graph-store text success output follows store contracts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "graph-store-text-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "graph-store-text.zova");
    {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
    }

    var create = try runCli(&.{ "zova", "graph-store", "create", store_path });
    defer create.deinit();
    const store_line = try std.fmt.allocPrint(std.testing.allocator, "path: {s}\n", .{store_path});
    defer std.testing.allocator.free(store_line);
    const main_line = try std.fmt.allocPrint(std.testing.allocator, "main_path: {s}\n", .{main_path});
    defer std.testing.allocator.free(main_line);
    try std.testing.expectEqual(@as(u8, 0), create.code);
    try expectContains(create.stdout, "graph-store-create: ok\n");
    try expectContains(create.stdout, store_line);
    try expectContains(create.stdout, "created: true\n");
    try expectContains(create.stdout, "bound: true\n");

    var bind = try runCli(&.{ "zova", "graph-store", "bind", main_path, store_path });
    defer bind.deinit();
    try std.testing.expectEqual(@as(u8, 0), bind.code);
    try expectContains(bind.stdout, "graph-store-bind: ok\n");
    try expectContains(bind.stdout, main_line);
    try expectContains(bind.stdout, store_line);
    try expectContains(bind.stdout, "store_id: ");
    try expectContains(bind.stdout, "bound: true\n");

    var info = try runCli(&.{ "zova", "graph-store", "info", main_path });
    defer info.deinit();
    try std.testing.expectEqual(@as(u8, 0), info.code);
    try expectContains(info.stdout, "graph-store-info: ok\n");
    try expectContains(info.stdout, main_line);
    try expectContains(info.stdout, store_line);
    try expectContains(info.stdout, "store_id: ");
    try expectContains(info.stdout, "bound: true\n");

    var unbind = try runCli(&.{ "zova", "graph-store", "unbind", main_path });
    defer unbind.deinit();
    try std.testing.expectEqual(@as(u8, 0), unbind.code);
    try expectContains(unbind.stdout, "graph-store-unbind: ok\n");
    try expectContains(unbind.stdout, main_line);
    try expectContains(unbind.stdout, "bound: false\n");
}

test "cli split graphs moves graph storage and reports exact counts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "split-graph-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "split-graph-store.zova");

    {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
        try db.createGraph("one");
        try db.createGraph("two");
        try db.putGraphNodes(&.{
            .{ .graph_name = "one", .node_id = "a", .kind = "item", .target_type = .external, .target_ref = "a" },
            .{ .graph_name = "one", .node_id = "b", .kind = "item", .target_type = .external, .target_ref = "b" },
            .{ .graph_name = "two", .node_id = "c", .kind = "item", .target_type = .external, .target_ref = "c" },
            .{ .graph_name = "two", .node_id = "d", .kind = "item", .target_type = .external, .target_ref = "d" },
        });
        try db.putGraphEdges(&.{
            .{ .graph_name = "one", .from_node_id = "a", .edge_type = "next", .to_node_id = "b" },
            .{ .graph_name = "two", .from_node_id = "c", .edge_type = "next", .to_node_id = "d" },
            .{ .graph_name = "two", .from_node_id = "d", .edge_type = "next", .to_node_id = "c" },
        });
    }

    var split = try runCli(&.{ "zova", "split", "--graphs", "--json", main_path, store_path });
    defer split.deinit();
    try std.testing.expectEqual(@as(u8, 0), split.code);
    var parsed = try parseJson(split.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 13), root.count());
    try expectJsonInt(root, "cli_json_version", 1);
    try expectJsonString(root, "status", "ok");
    try expectJsonString(root, "command", "split");
    try expectJsonString(root, "role", "graphs");
    try expectJsonString(root, "main_path", main_path);
    try expectJsonString(root, "store_path", store_path);
    try expectJsonBool(root, "created", true);
    try expectJsonBool(root, "bound", true);
    try expectJsonBool(root, "verified", true);
    try std.testing.expectEqual(@as(usize, 64), root.get("store_id").?.string.len);
    try std.testing.expectEqual(@as(usize, 64), root.get("bound_set_id").?.string.len);
    const copied = root.get("copied").?.object;
    try std.testing.expectEqual(@as(usize, 3), copied.count());
    try expectJsonInt(copied, "graphs", 2);
    try expectJsonInt(copied, "nodes", 4);
    try expectJsonInt(copied, "edges", 3);
    const cleared = root.get("cleared").?.object;
    try std.testing.expectEqual(@as(usize, 3), cleared.count());
    try expectJsonInt(cleared, "graphs", 2);
    try expectJsonInt(cleared, "nodes", 4);
    try expectJsonInt(cleared, "edges", 3);

    var db = try zova.Database.open(main_path);
    defer db.deinit();
    try std.testing.expect(try db.hasGraphEdge("two", "d", "next", "c"));
    try std.testing.expectEqual(@as(i64, 0), try countRawRows(&db.sqlite_db, "select count(*) from main._zova_graphs"));
}

test "cli split graphs text output reports exact labels and counts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "split-graph-text-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "split-graph-text-store.zova");
    {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
        try db.createGraph("graph");
        try db.putGraphNodes(&.{
            .{ .graph_name = "graph", .node_id = "a", .kind = "item", .target_type = .external, .target_ref = "a" },
            .{ .graph_name = "graph", .node_id = "b", .kind = "item", .target_type = .external, .target_ref = "b" },
        });
        try db.putGraphEdge(.{ .graph_name = "graph", .from_node_id = "a", .edge_type = "next", .to_node_id = "b" });
    }
    var split = try runCli(&.{ "zova", "split", "--graphs", main_path, store_path });
    defer split.deinit();
    const main_line = try std.fmt.allocPrint(std.testing.allocator, "main_path: {s}\n", .{main_path});
    defer std.testing.allocator.free(main_line);
    const store_line = try std.fmt.allocPrint(std.testing.allocator, "store_path: {s}\n", .{store_path});
    defer std.testing.allocator.free(store_line);
    try std.testing.expectEqual(@as(u8, 0), split.code);
    try expectContains(split.stdout, "split: ok\n");
    try expectContains(split.stdout, "role: graphs\n");
    try expectContains(split.stdout, main_line);
    try expectContains(split.stdout, store_line);
    try expectContains(split.stdout, "copied_graphs: 1\n");
    try expectContains(split.stdout, "copied_nodes: 2\n");
    try expectContains(split.stdout, "copied_edges: 1\n");
    try expectContains(split.stdout, "cleared_graphs: 1\n");
    try expectContains(split.stdout, "cleared_nodes: 2\n");
    try expectContains(split.stdout, "cleared_edges: 1\n");
    try expectContains(split.stdout, "verified: true\n");
}

test "cli graph-store validates usage migration and store roles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "graph-bind-main.zova");
    var graph_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const graph_store_path = try testingDbPath(&graph_store_buffer, tmp.sub_path[0..], "graph-bind-store.zova");
    var invalid_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const invalid_store_path = try testingDbPath(&invalid_store_buffer, tmp.sub_path[0..], "object-not-graph.zova");
    var empty_main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const empty_main_path = try testingDbPath(&empty_main_buffer, tmp.sub_path[0..], "graph-bind-empty-main.zova");

    {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
        try db.createGraph("existing");
    }
    {
        var db = try zova.Database.create(empty_main_path);
        defer db.deinit();
    }
    try zova.createGraphStore(graph_store_path);
    try zova.createObjectStore(invalid_store_path);

    var migration = try runCli(&.{ "zova", "graph-store", "bind", main_path, graph_store_path });
    defer migration.deinit();
    try std.testing.expectEqual(@as(u8, 3), migration.code);
    try expectContains(migration.stderr, "split --graphs");

    var invalid = try runCli(&.{ "zova", "graph-store", "bind", "--json", empty_main_path, invalid_store_path });
    defer invalid.deinit();
    try std.testing.expectEqual(@as(u8, 3), invalid.code);
    var invalid_json = try parseJson(invalid.stderr);
    defer invalid_json.deinit();
    try expectJsonString(invalid_json.value.object, "command", "graph-store-bind");

    const usage_cases = [_][]const []const u8{
        &.{ "zova", "graph-store" },
        &.{ "zova", "graph-store", "bind", main_path },
        &.{ "zova", "graph-store", "info", main_path, graph_store_path },
        &.{ "zova", "split", "--graphs", "--objects", main_path, graph_store_path },
        &.{ "zova", "split", "--graphs", main_path, main_path },
    };
    for (usage_cases) |case| {
        var result = try runCli(case);
        defer result.deinit();
        try std.testing.expectEqual(@as(u8, 2), result.code);
    }

    var missing = try runCli(&.{ "zova", "graph-store", "bind", empty_main_path, "missing-graph-store.zova" });
    defer missing.deinit();
    try std.testing.expectEqual(@as(u8, 3), missing.code);
}

test "cli doctor and check report healthy bound object stores" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-health-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-health-objects.zova");

    {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
        try zova.createObjectStore(store_path);
        try db.bindObjectStore(store_path);
        _ = try db.putObject("bound store diagnostic object");
    }

    var doctor = try runCli(&.{ "zova", "doctor", "--json", main_path });
    defer doctor.deinit();
    try std.testing.expectEqual(@as(u8, 0), doctor.code);
    var doctor_json = try parseJson(doctor.stdout);
    defer doctor_json.deinit();
    const doctor_root = doctor_json.value.object;
    try expectJsonString(doctor_root, "status", "ok");
    try expectJsonInt(doctor_root, "issue_count", 0);
    try std.testing.expectEqual(@as(i64, 0), try jsonObjectInt(doctor_root, "issue_counts", "bound_store"));
    try std.testing.expect(std.mem.indexOf(u8, doctor.stdout, "bound store diagnostic object") == null);

    var check = try runCli(&.{ "zova", "check", "--deep", "--json", main_path });
    defer check.deinit();
    try std.testing.expectEqual(@as(u8, 0), check.code);
    var check_json = try parseJson(check.stdout);
    defer check_json.deinit();
    const check_root = check_json.value.object;
    try expectJsonString(check_root, "status", "ok");
    try expectJsonInt(check_root, "issue_count", 0);
    try std.testing.expectEqual(@as(i64, 0), try jsonObjectInt(check_root, "issue_counts", "bound_store"));
    try std.testing.expect((try jsonObjectInt(check_root, "checked", "objects")) > 0);
}

test "cli doctor and check categorize bound object store marker failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-marker-main.zova");

    var missing_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing_store_path = try testingDbPath(&missing_store_buffer, tmp.sub_path[0..], "bound-marker-missing.zova");

    {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
        try zova.createObjectStore(missing_store_path);
        try db.bindObjectStore(missing_store_path);
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.deleteFile(io, "bound-marker-missing.zova");

    var missing_doctor = try runCli(&.{ "zova", "doctor", main_path });
    defer missing_doctor.deinit();
    try std.testing.expectEqual(@as(u8, 4), missing_doctor.code);
    try expectContains(missing_doctor.stderr, "bound_store_issues:");
    try expectContains(missing_doctor.stderr, "missing_or_unreadable_store");
    try expectContains(missing_doctor.stderr, "zova object-store bind");

    var missing_check = try runCli(&.{ "zova", "check", "--deep", "--json", main_path });
    defer missing_check.deinit();
    try std.testing.expectEqual(@as(u8, 4), missing_check.code);
    var missing_check_json = try parseJson(missing_check.stderr);
    defer missing_check_json.deinit();
    const missing_root = missing_check_json.value.object;
    try expectJsonString(missing_root, "command", "check");
    try std.testing.expect((try jsonObjectInt(missing_root, "issue_counts", "bound_store")) > 0);
    try expectContains(missing_check.stderr, "missing_or_unreadable_store");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-marker-objects.zova");

    {
        var db = try zova.Database.openForObjectStoreManagement(main_path, .{});
        defer db.deinit();
        try zova.createObjectStore(store_path);
        try db.bindObjectStore(store_path);
        _ = try db.putObject("bound epoch object");
    }

    {
        var store = try zova.sqlite.Database.open(store_path);
        defer store.deinit();
        try store.exec("update _zova_meta set value = '999' where key = 'object_epoch'");
    }

    var epoch_doctor = try runCli(&.{ "zova", "doctor", "--json", main_path });
    defer epoch_doctor.deinit();
    try std.testing.expectEqual(@as(u8, 4), epoch_doctor.code);
    var epoch_doctor_json = try parseJson(epoch_doctor.stderr);
    defer epoch_doctor_json.deinit();
    const epoch_root = epoch_doctor_json.value.object;
    try expectJsonString(epoch_root, "command", "doctor");
    try std.testing.expect((try jsonObjectInt(epoch_root, "issue_counts", "bound_store")) > 0);
    try expectContains(epoch_doctor.stderr, "object_epoch_mismatch");
    try std.testing.expect(std.mem.indexOf(u8, epoch_doctor.stderr, "zova object-store bind") == null);
    try std.testing.expect(std.mem.indexOf(u8, epoch_doctor.stderr, "bound epoch object") == null);
}

test "cli doctor categorizes bound vector store marker failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var missing_main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing_main_path = try testingDbPath(&missing_main_buffer, tmp.sub_path[0..], "bound-vector-missing-main.zova");

    var missing_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing_store_path = try testingDbPath(&missing_store_buffer, tmp.sub_path[0..], "bound-vector-missing-vectors.zova");

    {
        var db = try zova.Database.create(missing_main_path);
        defer db.deinit();
        try zova.createVectorStore(missing_store_path);
        try db.bindVectorStore(missing_store_path);
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.deleteFile(io, "bound-vector-missing-vectors.zova");

    var missing_doctor = try runCli(&.{ "zova", "doctor", missing_main_path });
    defer missing_doctor.deinit();
    try std.testing.expectEqual(@as(u8, 4), missing_doctor.code);
    try expectContains(missing_doctor.stderr, "bound_store_issues:");
    try expectContains(missing_doctor.stderr, "missing_or_unreadable_store");
    try expectContains(missing_doctor.stderr, "zova vector-store bind");

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-vector-marker-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-vector-marker-vectors.zova");

    {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
        try zova.createVectorStore(store_path);
        try db.bindVectorStore(store_path);
        try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
        try db.putVector("docs", "private-vector-id", .{ .f32 = &.{ 1.0, 2.0 } });
    }

    {
        var store = try zova.sqlite.Database.open(store_path);
        defer store.deinit();
        try store.exec("update _zova_meta set value = '999' where key = 'vector_epoch'");
    }

    var doctor = try runCli(&.{ "zova", "doctor", "--json", main_path });
    defer doctor.deinit();
    try std.testing.expectEqual(@as(u8, 4), doctor.code);
    var doctor_json = try parseJson(doctor.stderr);
    defer doctor_json.deinit();
    const root = doctor_json.value.object;
    try expectJsonString(root, "command", "doctor");
    try std.testing.expect((try jsonObjectInt(root, "issue_counts", "bound_store")) > 0);
    try expectContains(doctor.stderr, "vector_epoch_mismatch");
    try std.testing.expect(std.mem.indexOf(u8, doctor.stderr, "private-vector-id") == null);
}

test "cli doctor validates bound graph store identity and epoch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-graph-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-graph-store.zova");

    {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
        try zova.createGraphStore(store_path);
        try db.bindGraphStore(store_path);
        try db.createGraph("diagnostic");
    }

    var healthy = try runCli(&.{ "zova", "doctor", "--json", main_path });
    defer healthy.deinit();
    try std.testing.expectEqual(@as(u8, 0), healthy.code);
    var healthy_json = try parseJson(healthy.stdout);
    defer healthy_json.deinit();
    try std.testing.expectEqual(@as(i64, 0), try jsonObjectInt(healthy_json.value.object, "issue_counts", "bound_store"));

    {
        var store = try zova.sqlite.Database.open(store_path);
        defer store.deinit();
        try store.exec("update _zova_meta set value = '999' where key = 'graph_epoch'");
    }

    var mismatch = try runCli(&.{ "zova", "doctor", "--json", main_path });
    defer mismatch.deinit();
    try std.testing.expectEqual(@as(u8, 4), mismatch.code);
    try expectContains(mismatch.stderr, "graph_epoch_mismatch");
    var mismatch_json = try parseJson(mismatch.stderr);
    defer mismatch_json.deinit();
    try std.testing.expect((try jsonObjectInt(mismatch_json.value.object, "issue_counts", "bound_store")) > 0);
}

test "cli doctor categorizes every bound graph store marker failure" {
    const cases = [_]struct { name: []const u8, sql: [:0]const u8, kind: []const u8 }{
        .{ .name = "magic", .sql = "update _zova_meta set value = 'wrong' where key = 'magic'", .kind = "store_magic_mismatch" },
        .{ .name = "format", .sql = "update _zova_meta set value = '999' where key = 'format_version'", .kind = "store_format_version_mismatch" },
        .{ .name = "role", .sql = "update _zova_meta set value = 'object_store' where key = 'store_role'", .kind = "store_role_mismatch" },
        .{ .name = "store-id", .sql = "update _zova_meta set value = replace(value, substr(value, 1, 1), case substr(value, 1, 1) when '0' then '1' else '0' end) where key = 'store_id'", .kind = "store_id_mismatch" },
        .{ .name = "bound-set", .sql = "update _zova_meta set value = replace(value, substr(value, 1, 1), case substr(value, 1, 1) when '0' then '1' else '0' end) where key = 'bound_set_id'", .kind = "bound_set_id_mismatch" },
        .{ .name = "epoch-missing", .sql = "delete from _zova_meta where key = 'graph_epoch'", .kind = "missing_graph_epoch" },
        .{ .name = "epoch-unreadable", .sql = "alter table _zova_meta rename to saved_meta; create view _zova_meta as select key, case when key = 'graph_epoch' then json_extract('invalid', '$') else value end as value from saved_meta", .kind = "graph_epoch_unreadable" },
        .{ .name = "epoch-text", .sql = "update _zova_meta set value = 'not-an-integer' where key = 'graph_epoch'", .kind = "graph_epoch_invalid" },
        .{ .name = "epoch-negative", .sql = "update _zova_meta set value = '-1' where key = 'graph_epoch'", .kind = "graph_epoch_invalid" },
        .{ .name = "epoch-mismatch", .sql = "update _zova_meta set value = '999' where key = 'graph_epoch'", .kind = "graph_epoch_mismatch" },
    };

    inline for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], case.name ++ "-main.zova");
        var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], case.name ++ "-store.zova");
        {
            var db = try zova.Database.create(main_path);
            defer db.deinit();
            try zova.createGraphStore(store_path);
            try db.bindGraphStore(store_path);
        }
        {
            var store = try zova.sqlite.Database.open(store_path);
            defer store.deinit();
            try store.exec(case.sql);
        }
        var doctor = try runCli(&.{ "zova", "doctor", "--json", main_path });
        defer doctor.deinit();
        try std.testing.expectEqual(@as(u8, 4), doctor.code);
        try expectContains(doctor.stderr, case.kind);
        try expectContains(doctor.stderr, "\"area\": \"bound_store\"");
        try expectContains(doctor.stderr, "\"severity\": \"error\"");
    }
}

test "cli missing bound store guidance is role specific" {
    const roles = [_]struct { name: []const u8, expected: []const u8, absent_one: []const u8, absent_two: []const u8 }{
        .{ .name = "object", .expected = "zova object-store bind", .absent_one = "zova vector-store bind", .absent_two = "zova graph-store bind" },
        .{ .name = "vector", .expected = "zova vector-store bind", .absent_one = "zova object-store bind", .absent_two = "zova graph-store bind" },
        .{ .name = "graph", .expected = "zova graph-store bind", .absent_one = "zova object-store bind", .absent_two = "zova vector-store bind" },
    };
    inline for (roles) |role| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], role.name ++ "-missing-main.zova");
        var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], role.name ++ "-missing-store.zova");
        {
            var db = try zova.Database.create(main_path);
            defer db.deinit();
            if (std.mem.eql(u8, role.name, "object")) {
                try zova.createObjectStore(store_path);
                try db.bindObjectStore(store_path);
            } else if (std.mem.eql(u8, role.name, "vector")) {
                try zova.createVectorStore(store_path);
                try db.bindVectorStore(store_path);
            } else {
                try zova.createGraphStore(store_path);
                try db.bindGraphStore(store_path);
            }
        }
        try tmp.dir.deleteFile(std.Io.Threaded.global_single_threaded.io(), role.name ++ "-missing-store.zova");
        var doctor = try runCli(&.{ "zova", "doctor", main_path });
        defer doctor.deinit();
        try std.testing.expectEqual(@as(u8, 4), doctor.code);
        try expectContains(doctor.stderr, role.expected);
        try std.testing.expect(std.mem.indexOf(u8, doctor.stderr, role.absent_one) == null);
        try std.testing.expect(std.mem.indexOf(u8, doctor.stderr, role.absent_two) == null);
        var check = try runCli(&.{ "zova", "check", "--deep", main_path });
        defer check.deinit();
        try std.testing.expectEqual(@as(u8, 4), check.code);
        try expectContains(check.stderr, role.expected);
        try std.testing.expect(std.mem.indexOf(u8, check.stderr, role.absent_one) == null);
        try std.testing.expect(std.mem.indexOf(u8, check.stderr, role.absent_two) == null);
    }
}

test "cli deep check includes bound graph store quick check" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "graph-quick-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "graph-quick-store.zova");

    {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
        try zova.createGraphStore(store_path);
        try db.bindGraphStore(store_path);
    }
    {
        var store = try zova.sqlite.Database.open(store_path);
        defer store.deinit();
        try store.exec("pragma ignore_check_constraints = on");
        try store.exec("insert into _zova_graphs (name, created_order) values ('', 1)");
        try store.exec("pragma ignore_check_constraints = off");
    }

    var check = try runCli(&.{ "zova", "check", "--deep", "--json", main_path });
    defer check.deinit();
    try std.testing.expectEqual(@as(u8, 4), check.code);
    try expectContains(check.stderr, "sqlite quick_check failed");
    try expectContains(check.stderr, "CheckFailed");
}

test "cli graph inspection reads the active bound graph store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "graph-inspect-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "graph-inspect-store.zova");
    {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
        try zova.createGraphStore(store_path);
        try db.bindGraphStore(store_path);
        try db.createGraph("bound");
        try db.putGraphNode(.{ .graph_name = "bound", .node_id = "node", .kind = "item" });
        try db.putGraphNode(.{ .graph_name = "bound", .node_id = "other", .kind = "item" });
        try db.putGraphEdge(.{ .graph_name = "bound", .from_node_id = "node", .edge_type = "next", .to_node_id = "other" });
        try std.testing.expectEqual(@as(i64, 0), try countRawRows(&db.sqlite_db, "select count(*) from main._zova_graphs"));
    }

    var graphs = try runCli(&.{ "zova", "graphs", "--json", main_path });
    defer graphs.deinit();
    try std.testing.expectEqual(@as(u8, 0), graphs.code);
    try expectContains(graphs.stdout, "bound");
    var graph = try runCli(&.{ "zova", "graph", "--json", main_path, "bound" });
    defer graph.deinit();
    try std.testing.expectEqual(@as(u8, 0), graph.code);
    try expectContains(graph.stdout, "\"node_count\": 2");
    var node = try runCli(&.{ "zova", "graph-node", "--json", main_path, "bound", "node" });
    defer node.deinit();
    try std.testing.expectEqual(@as(u8, 0), node.code);
    try expectContains(node.stdout, "\"node_id\": \"node\"");
    var neighbors = try runCli(&.{ "zova", "graph-neighbors", "--json", main_path, "bound", "node" });
    defer neighbors.deinit();
    try std.testing.expectEqual(@as(u8, 0), neighbors.code);
    try expectContains(neighbors.stdout, "\"node_id\": \"other\"");
    var walk = try runCli(&.{ "zova", "graph-walk", "--json", main_path, "bound", "node" });
    defer walk.deinit();
    try std.testing.expectEqual(@as(u8, 0), walk.code);
    try expectContains(walk.stdout, "\"node_id\": \"other\"");
}

test "cli doctor reports existing bound store with unreadable metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-unreadable-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-unreadable-objects.zova");

    {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
        try zova.createObjectStore(store_path);
        try db.bindObjectStore(store_path);
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.deleteFile(io, "bound-unreadable-objects.zova");
    {
        var plain = try zova.sqlite.Database.open(store_path);
        defer plain.deinit();
        try plain.exec("create table plain (id integer primary key)");
    }

    var doctor = try runCli(&.{ "zova", "doctor", "--json", main_path });
    defer doctor.deinit();
    try std.testing.expectEqual(@as(u8, 4), doctor.code);
    var parsed = try parseJson(doctor.stderr);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonString(root, "command", "doctor");
    try std.testing.expect((try jsonObjectInt(root, "issue_counts", "bound_store")) > 0);
    try expectContains(doctor.stderr, "store_magic_unreadable");
}

test "cli info reports bounded database summary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "info.zova");
    try createHealthyDatabase(db_path);

    var result = try runCli(&.{ "zova", "info", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try expectContains(result.stdout, "Zova database");
    try expectContains(result.stdout, "format_version: 10");
    try expectContains(result.stdout, "objects:");
    try expectContains(result.stdout, "chunks:");
    try expectContains(result.stdout, "loose_chunks:");
    try expectContains(result.stdout, "vector_collections:");
    try expectContains(result.stdout, "user_tables:");
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello object") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "7.25") == null);
}

test "cli info reports kv storage diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "kv-info.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.kvPut("settings", "theme", "dark");
    try db.kvPut("settings", "retries", "\x00\x01\x02");
    try db.kvPut("cache", "k1", "v1");
    try db.kvPut("cache", "k2", "v2");
    try db.kvPut("cache", "k3", "v3");

    var result = try runCli(&.{ "zova", "info", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try expectContains(result.stdout, "kv_entries: 5");
    try expectContains(result.stdout, "kv_logical_bytes:");
    try expectContains(result.stdout, "kv_allocated_bytes:");

    var json = try runCli(&.{ "zova", "info", "--json", db_path });
    defer json.deinit();
    try std.testing.expectEqual(@as(u8, 0), json.code);
    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 5), try jsonObjectInt(root, "kv", "entries"));
    _ = try jsonObjectInt(root, "kv", "logical_bytes");
    _ = try jsonObjectInt(root, "kv", "allocated_bytes");
}

test "cli backup compact and restore create usable copies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "ops-source.zova");

    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "ops-backup.zova");

    var compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = try testingDbPath(&compact_buffer, tmp.sub_path[0..], "ops-compact.zova");

    var restored_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const restored_path = try testingDbPath(&restored_buffer, tmp.sub_path[0..], "ops-restored.zova");

    try createHealthyDatabase(source_path);

    var backup = try runCli(&.{ "zova", "backup", source_path, backup_path });
    defer backup.deinit();
    try std.testing.expectEqual(@as(u8, 0), backup.code);
    try expectContains(backup.stdout, "backup: ok");
    try expectContains(backup.stdout, "verified: true");

    var compact = try runCli(&.{ "zova", "compact", "--json", "--no-verify", source_path, compact_path });
    defer compact.deinit();
    try std.testing.expectEqual(@as(u8, 0), compact.code);
    var compact_json = try parseJson(compact.stdout);
    defer compact_json.deinit();
    try expectJsonString(compact_json.value.object, "command", "compact");
    try expectJsonBool(compact_json.value.object, "verified", false);

    var restore = try runCli(&.{ "zova", "restore", "--json", backup_path, restored_path });
    defer restore.deinit();
    try std.testing.expectEqual(@as(u8, 0), restore.code);
    var restore_json = try parseJson(restore.stdout);
    defer restore_json.deinit();
    try expectJsonString(restore_json.value.object, "command", "restore");
    try expectJsonBool(restore_json.value.object, "verified", true);

    try expectHealthyCopy(backup_path);
    try expectHealthyCopy(compact_path);
    try expectHealthyCopy(restored_path);

    var backup_check = try runCli(&.{ "zova", "check", backup_path });
    defer backup_check.deinit();
    try std.testing.expectEqual(@as(u8, 0), backup_check.code);

    var backup_deep = try runCli(&.{ "zova", "check", "--deep", backup_path });
    defer backup_deep.deinit();
    try std.testing.expectEqual(@as(u8, 0), backup_deep.code);

    var compact_deep = try runCli(&.{ "zova", "check", "--deep", compact_path });
    defer compact_deep.deinit();
    try std.testing.expectEqual(@as(u8, 0), compact_deep.code);

    var restored_deep = try runCli(&.{ "zova", "check", "--deep", restored_path });
    defer restored_deep.deinit();
    try std.testing.expectEqual(@as(u8, 0), restored_deep.code);
}

test "cli operational commands report usage path and verification failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "ops-errors-source.zova");

    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "ops-errors-backup.zova");

    var existing_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const existing_path = try testingDbPath(&existing_buffer, tmp.sub_path[0..], "ops-errors-existing.zova");

    var invalid_source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const invalid_source_path = try testingDbPath(&invalid_source_buffer, tmp.sub_path[0..], "ops-errors-source.db");

    var corrupt_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const corrupt_path = try testingDbPath(&corrupt_buffer, tmp.sub_path[0..], "ops-errors-corrupt.zova");

    var corrupt_backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const corrupt_backup_path = try testingDbPath(&corrupt_backup_buffer, tmp.sub_path[0..], "ops-errors-corrupt-backup.zova");

    try createHealthyDatabase(source_path);
    try createHealthyDatabase(existing_path);
    try createCorruptObjectDatabase(corrupt_path);

    var duplicate_json = try runCli(&.{ "zova", "backup", "--json", "--json", source_path, backup_path });
    defer duplicate_json.deinit();
    try std.testing.expectEqual(@as(u8, 2), duplicate_json.code);
    try expectContains(duplicate_json.stderr, "\"status\": \"error\"");

    var missing_arg = try runCli(&.{ "zova", "compact", source_path });
    defer missing_arg.deinit();
    try std.testing.expectEqual(@as(u8, 2), missing_arg.code);

    var invalid_source = try runCli(&.{ "zova", "backup", invalid_source_path, backup_path });
    defer invalid_source.deinit();
    try std.testing.expectEqual(@as(u8, 3), invalid_source.code);

    var existing_dest = try runCli(&.{ "zova", "backup", source_path, existing_path });
    defer existing_dest.deinit();
    try std.testing.expectEqual(@as(u8, 3), existing_dest.code);
    try expectContains(existing_dest.stderr, "DestinationExists");

    var verification = try runCli(&.{ "zova", "backup", "--json", corrupt_path, corrupt_backup_path });
    defer verification.deinit();
    try std.testing.expectEqual(@as(u8, 4), verification.code);
    try expectContains(verification.stderr, "verification failed");
}

test "cli info json reports bounded database summary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "info-json.zova");
    try createHealthyDatabase(db_path);

    var result = try runCli(&.{ "zova", "info", "--json", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonInt(root, "cli_json_version", 1);
    try expectJsonString(root, "package_version", cli.package_version);
    try expectJsonString(root, "sqlite_version", zova.sqlite.version());
    try expectJsonString(root, "format_version", "10");
    try expectJsonObjectHasInt(root, "files", "database_bytes");
    try expectJsonObjectHasInt(root, "sqlite", "page_count");
    try expectJsonObjectHasInt(root, "objects", "count");
    try expectJsonObjectHasInt(root, "objects", "logical_bytes");
    try expectJsonObjectHasInt(root, "chunks", "count");
    try expectJsonObjectHasInt(root, "chunks", "manifest_rows");
    try expectJsonObjectHasInt(root, "chunks", "loose_count");
    try expectJsonObjectHasInt(root, "vectors", "collections");
    try expectJsonObjectHasInt(root, "kv", "entries");
    try expectJsonObjectHasInt(root, "kv", "logical_bytes");
    try expectJsonObjectHasInt(root, "kv", "allocated_bytes");
    try expectJsonObjectHasInt(root, "tables", "user");
    try expectJsonObjectHasInt(root, "tables", "private");
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello object") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "streamed object") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "_zova_objects") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "7.25") == null);
}

test "cli stats reports deeper bounded database summary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "stats.zova");
    try createHealthyDatabase(db_path);

    var result = try runCli(&.{ "zova", "stats", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try expectContains(result.stdout, "Zova stats");
    try expectContains(result.stdout, "object_size_min:");
    try expectContains(result.stdout, "object_chunk_count_avg:");
    try expectContains(result.stdout, "chunk_size_max:");
    try expectContains(result.stdout, "loose_chunk_bytes:");
    try expectContains(result.stdout, "deduped_bytes_saved:");
    try expectContains(result.stdout, "vector_collections:");
    try expectContains(result.stdout, "top_objects:");
    try expectContains(result.stdout, "top_chunks:");
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello object") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "streamed object") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hidden chunk bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "7.25") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "_zova_objects") == null);
}

test "cli stats json reports deeper bounded database summary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "stats-json.zova");
    try createHealthyDatabase(db_path);

    var result = try runCli(&.{ "zova", "stats", "--json", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonInt(root, "cli_json_version", 1);
    try expectJsonString(root, "status", "ok");
    try expectJsonString(root, "command", "stats");
    try expectJsonInt(root, "limit", 10);
    try expectJsonObjectHasInt(root, "objects", "count");
    try expectJsonObjectHasInt(root, "objects", "size_min");
    try expectJsonObjectHasInt(root, "objects", "chunk_count_max");
    try expectJsonObjectHasInt(root, "chunks", "loose_bytes");
    try expectJsonObjectHasInt(root, "chunks", "deduped_bytes_saved");
    try expectJsonArray(root, "vector_collections");
    try expectJsonArray(root, "top_objects");
    try expectJsonArray(root, "top_chunks");
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello object") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "streamed object") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "_zova_objects") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "7.25") == null);
}

test "cli stats limit bounds top lists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "stats-limit.zova");
    try createHealthyDatabase(db_path);

    var zero = try runCli(&.{ "zova", "stats", "--json", "--limit", "0", db_path });
    defer zero.deinit();
    try std.testing.expectEqual(@as(u8, 0), zero.code);
    var zero_json = try parseJson(zero.stdout);
    defer zero_json.deinit();
    try expectJsonInt(zero_json.value.object, "limit", 0);
    try expectJsonArrayLen(zero_json.value.object, "top_objects", 0);
    try expectJsonArrayLen(zero_json.value.object, "top_chunks", 0);

    var one = try runCli(&.{ "zova", "stats", "--limit", "1", "--json", db_path });
    defer one.deinit();
    try std.testing.expectEqual(@as(u8, 0), one.code);
    var one_json = try parseJson(one.stdout);
    defer one_json.deinit();
    try expectJsonInt(one_json.value.object, "limit", 1);
    try expectJsonArrayLen(one_json.value.object, "top_objects", 1);
    try expectJsonArrayLen(one_json.value.object, "top_chunks", 1);
}

test "cli stats usage and open failures use existing exit codes" {
    const usage_cases = [_][]const []const u8{
        &.{ "zova", "stats", "--wat", "x.zova" },
        &.{ "zova", "stats", "--json", "--json", "x.zova" },
        &.{ "zova", "stats", "--limit", "1", "--limit", "2", "x.zova" },
        &.{ "zova", "stats", "--limit", "nope", "x.zova" },
        &.{ "zova", "stats", "--limit" },
        &.{ "zova", "stats", "--limit", "101", "x.zova" },
        &.{ "zova", "stats", "x.zova", "extra" },
    };

    for (usage_cases) |args| {
        var result = try runCli(args);
        defer result.deinit();
        try std.testing.expectEqual(@as(u8, 2), result.code);
    }

    var missing = try runCli(&.{ "zova", "stats", "--json", "missing.zova" });
    defer missing.deinit();
    try std.testing.expectEqual(@as(u8, 3), missing.code);
    var missing_json = try parseJson(missing.stderr);
    defer missing_json.deinit();
    try expectJsonString(missing_json.value.object, "command", "stats");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const sqlite_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "plain-stats.db");
    {
        var raw = try zova.sqlite.Database.open(sqlite_path);
        defer raw.deinit();
        try raw.exec("create table plain (id integer primary key)");
    }

    var plain = try runCli(&.{ "zova", "stats", sqlite_path });
    defer plain.deinit();
    try std.testing.expectEqual(@as(u8, 3), plain.code);
}

test "cli object and chunk inspection commands report bounded summaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "inspect.zova");
    try createHealthyDatabase(db_path);

    const object_id = try queryText(db_path, "select lower(hex(object_id)) from _zova_objects order by hex(object_id) limit 1");
    defer std.testing.allocator.free(object_id);
    const chunk_id = try queryText(db_path, "select lower(hex(chunk_hash)) from _zova_chunks order by hex(chunk_hash) limit 1");
    defer std.testing.allocator.free(chunk_id);

    var objects_text = try runCli(&.{ "zova", "objects", db_path });
    defer objects_text.deinit();
    try std.testing.expectEqual(@as(u8, 0), objects_text.code);
    try expectContains(objects_text.stdout, "Zova objects");
    try expectContains(objects_text.stdout, object_id);
    try expectContains(objects_text.stdout, "size_bytes=");
    try expectContains(objects_text.stdout, "chunk_count=");
    try std.testing.expect(std.mem.indexOf(u8, objects_text.stdout, "hello object") == null);
    try std.testing.expect(std.mem.indexOf(u8, objects_text.stdout, "hidden chunk bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, objects_text.stdout, "_zova_objects") == null);

    var objects_json = try runCli(&.{ "zova", "objects", "--json", db_path });
    defer objects_json.deinit();
    try std.testing.expectEqual(@as(u8, 0), objects_json.code);
    var parsed_objects = try parseJson(objects_json.stdout);
    defer parsed_objects.deinit();
    const objects_root = parsed_objects.value.object;
    try expectJsonString(objects_root, "command", "objects");
    try expectJsonInt(objects_root, "limit", 10);
    try expectJsonArray(objects_root, "objects");

    var object_json = try runCli(&.{ "zova", "object", "--json", db_path, object_id });
    defer object_json.deinit();
    try std.testing.expectEqual(@as(u8, 0), object_json.code);
    var parsed_object = try parseJson(object_json.stdout);
    defer parsed_object.deinit();
    const object_root = parsed_object.value.object;
    try expectJsonString(object_root, "command", "object");
    try expectJsonString(object_root, "object_id", object_id);
    try expectJsonArray(object_root, "manifest");
    try std.testing.expect(std.mem.indexOf(u8, object_json.stdout, "hello object") == null);

    var chunks_text = try runCli(&.{ "zova", "chunks", db_path });
    defer chunks_text.deinit();
    try std.testing.expectEqual(@as(u8, 0), chunks_text.code);
    try expectContains(chunks_text.stdout, "Zova chunks");
    try expectContains(chunks_text.stdout, chunk_id);
    try expectContains(chunks_text.stdout, "reference_count=");
    try expectContains(chunks_text.stdout, "is_unreferenced=");
    try std.testing.expect(std.mem.indexOf(u8, chunks_text.stdout, "hidden chunk bytes") == null);

    var chunk_json = try runCli(&.{ "zova", "chunk", "--json", db_path, chunk_id });
    defer chunk_json.deinit();
    try std.testing.expectEqual(@as(u8, 0), chunk_json.code);
    var parsed_chunk = try parseJson(chunk_json.stdout);
    defer parsed_chunk.deinit();
    const chunk_root = parsed_chunk.value.object;
    try expectJsonString(chunk_root, "command", "chunk");
    try expectJsonString(chunk_root, "chunk_hash", chunk_id);
    try expectJsonObjectHasInt(chunk_root, "chunk", "size_bytes");
    try expectJsonArray(chunk_root, "references");
    try std.testing.expect(std.mem.indexOf(u8, chunk_json.stdout, "hidden chunk bytes") == null);
}

test "cli object and chunk inspection limits and uppercase ids work" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "inspect-limits.zova");
    try createHealthyDatabase(db_path);

    const object_id = try queryText(db_path, "select lower(hex(object_id)) from _zova_objects order by hex(object_id) limit 1");
    defer std.testing.allocator.free(object_id);
    const referenced_chunk_id = try queryText(db_path, "select lower(hex(chunk_hash)) from _zova_object_chunks order by hex(chunk_hash) limit 1");
    defer std.testing.allocator.free(referenced_chunk_id);
    const object_id_upper = try asciiUpperAlloc(object_id);
    defer std.testing.allocator.free(object_id_upper);
    const chunk_id_upper = try asciiUpperAlloc(referenced_chunk_id);
    defer std.testing.allocator.free(chunk_id_upper);

    var objects_zero = try runCli(&.{ "zova", "objects", "--json", "--limit", "0", db_path });
    defer objects_zero.deinit();
    try std.testing.expectEqual(@as(u8, 0), objects_zero.code);
    var objects_zero_json = try parseJson(objects_zero.stdout);
    defer objects_zero_json.deinit();
    try expectJsonArrayLen(objects_zero_json.value.object, "objects", 0);
    try expectJsonBool(objects_zero_json.value.object, "truncated", true);

    var object_zero = try runCli(&.{ "zova", "object", "--json", "--limit", "0", db_path, object_id_upper });
    defer object_zero.deinit();
    try std.testing.expectEqual(@as(u8, 0), object_zero.code);
    var object_zero_json = try parseJson(object_zero.stdout);
    defer object_zero_json.deinit();
    try expectJsonString(object_zero_json.value.object, "object_id", object_id);
    try expectJsonArrayLen(object_zero_json.value.object, "manifest", 0);
    try expectJsonBool(object_zero_json.value.object, "manifest_truncated", true);

    var chunks_one = try runCli(&.{ "zova", "chunks", "--limit", "1", "--json", db_path });
    defer chunks_one.deinit();
    try std.testing.expectEqual(@as(u8, 0), chunks_one.code);
    var chunks_one_json = try parseJson(chunks_one.stdout);
    defer chunks_one_json.deinit();
    try expectJsonArrayLen(chunks_one_json.value.object, "chunks", 1);
    try expectJsonBool(chunks_one_json.value.object, "truncated", true);

    var chunk_zero = try runCli(&.{ "zova", "chunk", "--json", "--limit", "0", db_path, chunk_id_upper });
    defer chunk_zero.deinit();
    try std.testing.expectEqual(@as(u8, 0), chunk_zero.code);
    var chunk_zero_json = try parseJson(chunk_zero.stdout);
    defer chunk_zero_json.deinit();
    try expectJsonString(chunk_zero_json.value.object, "chunk_hash", referenced_chunk_id);
    try expectJsonArrayLen(chunk_zero_json.value.object, "references", 0);
    try expectJsonBool(chunk_zero_json.value.object, "references_truncated", true);
}

test "cli object detail limit does not require full manifest validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "bounded-object-detail.zova");

    var object_id: zova.ObjectId = undefined;
    {
        var db = try zova.Database.create(db_path);
        defer db.deinit();

        const bytes = try std.testing.allocator.alloc(u8, 200 * 1024);
        defer std.testing.allocator.free(bytes);
        fillDeterministic(bytes);

        object_id = try db.putObject(bytes);

        var delete_later_manifest_rows = try db.prepare("delete from _zova_object_chunks where object_id = ? and chunk_index > 0");
        defer delete_later_manifest_rows.deinit();
        try delete_later_manifest_rows.bindBlob(1, &object_id);
        try std.testing.expectEqual(zova.sqlite.Step.done, try delete_later_manifest_rows.step());
    }

    const object_id_hex = try lowerHexAlloc(&object_id);
    defer std.testing.allocator.free(object_id_hex);

    var result = try runCli(&.{ "zova", "object", "--json", "--limit", "1", db_path, object_id_hex });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try expectJsonString(parsed.value.object, "command", "object");
    try expectJsonString(parsed.value.object, "object_id", object_id_hex);
    try expectJsonArrayLen(parsed.value.object, "manifest", 1);
    try expectJsonBool(parsed.value.object, "manifest_truncated", true);
}

test "cli object and chunk inspection usage and missing ids use expected exit codes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "inspect-errors.zova");
    try createHealthyDatabase(db_path);

    const usage_cases = [_][]const []const u8{
        &.{ "zova", "objects", "--wat", db_path },
        &.{ "zova", "objects", "--json", "--json", db_path },
        &.{ "zova", "objects", "--limit", "1", "--limit", "2", db_path },
        &.{ "zova", "objects", "--limit", "abc", db_path },
        &.{ "zova", "objects", "--limit" },
        &.{ "zova", "objects", db_path, "extra" },
        &.{ "zova", "object", db_path },
        &.{ "zova", "object", db_path, "abc" },
        &.{ "zova", "object", db_path, "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" },
        &.{ "zova", "object", db_path, missingHexId(), "extra" },
        &.{ "zova", "chunks", "--wat", db_path },
        &.{ "zova", "chunk", db_path },
        &.{ "zova", "chunk", db_path, "abc" },
        &.{ "zova", "chunk", db_path, "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" },
    };

    for (usage_cases) |args| {
        var result = try runCli(args);
        defer result.deinit();
        try std.testing.expectEqual(@as(u8, 2), result.code);
    }

    var duplicate_objects_json = try runCli(&.{ "zova", "objects", "--json", "--json", db_path });
    defer duplicate_objects_json.deinit();
    try std.testing.expectEqual(@as(u8, 2), duplicate_objects_json.code);
    var duplicate_objects_error = try parseJson(duplicate_objects_json.stderr);
    defer duplicate_objects_error.deinit();
    try expectJsonString(duplicate_objects_error.value.object, "command", "objects");

    var missing_limit_chunk_json = try runCli(&.{ "zova", "chunk", "--json", "--limit" });
    defer missing_limit_chunk_json.deinit();
    try std.testing.expectEqual(@as(u8, 2), missing_limit_chunk_json.code);
    var missing_limit_chunk_error = try parseJson(missing_limit_chunk_json.stderr);
    defer missing_limit_chunk_error.deinit();
    try expectJsonString(missing_limit_chunk_error.value.object, "command", "chunk");

    var missing_object = try runCli(&.{ "zova", "object", "--json", db_path, missingHexId() });
    defer missing_object.deinit();
    try std.testing.expectEqual(@as(u8, 4), missing_object.code);
    var missing_object_json = try parseJson(missing_object.stderr);
    defer missing_object_json.deinit();
    try expectJsonString(missing_object_json.value.object, "command", "object");

    var missing_chunk = try runCli(&.{ "zova", "chunk", db_path, missingHexId() });
    defer missing_chunk.deinit();
    try std.testing.expectEqual(@as(u8, 4), missing_chunk.code);
    try expectContains(missing_chunk.stderr, "not found");

    var missing_file = try runCli(&.{ "zova", "objects", "missing.zova" });
    defer missing_file.deinit();
    try std.testing.expectEqual(@as(u8, 3), missing_file.code);
}

test "cli vector and table inspection commands report bounded summaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vectors-tables.zova");
    try createHealthyDatabase(db_path);
    {
        var db = try zova.Database.open(db_path);
        defer db.deinit();
        try db.createVectorCollection("images", .{ .dimensions = 2, .metric = .dot });
        try db.putVectors("images", &.{
            .{ .id = "image-1", .values = .{ .f32 = &.{ 1.0, 2.0 } } },
            .{ .id = "image-2", .values = .{ .f32 = &.{ 2.0, 3.0 } } },
        });
    }

    var vectors_text = try runCli(&.{ "zova", "vectors", db_path });
    defer vectors_text.deinit();
    try std.testing.expectEqual(@as(u8, 0), vectors_text.code);
    try expectContains(vectors_text.stdout, "Zova vector collections");
    try expectContains(vectors_text.stdout, "docs");
    try expectContains(vectors_text.stdout, "images");
    try expectContains(vectors_text.stdout, "dimensions=");
    try expectContains(vectors_text.stdout, "stored_bytes=");
    try std.testing.expect(std.mem.indexOf(u8, vectors_text.stdout, "7.25") == null);

    var vectors_json = try runCli(&.{ "zova", "vectors", "--json", "--limit", "1", db_path });
    defer vectors_json.deinit();
    try std.testing.expectEqual(@as(u8, 0), vectors_json.code);
    var parsed_vectors = try parseJson(vectors_json.stdout);
    defer parsed_vectors.deinit();
    try expectJsonString(parsed_vectors.value.object, "command", "vectors");
    try expectJsonArrayLen(parsed_vectors.value.object, "collections", 1);
    try expectJsonBool(parsed_vectors.value.object, "truncated", true);
    try std.testing.expect(std.mem.indexOf(u8, vectors_json.stdout, "7.25") == null);

    var collection_json = try runCli(&.{ "zova", "vector-collection", "--json", "--limit", "1", db_path, "images" });
    defer collection_json.deinit();
    try std.testing.expectEqual(@as(u8, 0), collection_json.code);
    var parsed_collection = try parseJson(collection_json.stdout);
    defer parsed_collection.deinit();
    const collection_root = parsed_collection.value.object;
    try expectJsonString(collection_root, "command", "vector-collection");
    try expectJsonString(collection_root, "name", "images");
    try expectJsonInt(collection_root, "dimensions", 2);
    try expectJsonString(collection_root, "metric", "dot");
    try expectJsonArrayLen(collection_root, "vector_ids", 1);
    try expectJsonBool(collection_root, "vector_ids_truncated", true);
    try std.testing.expect(std.mem.indexOf(u8, collection_json.stdout, "2.0") == null);

    var tables_text = try runCli(&.{ "zova", "tables", db_path });
    defer tables_text.deinit();
    try std.testing.expectEqual(@as(u8, 0), tables_text.code);
    try expectContains(tables_text.stdout, "Zova tables");
    try expectContains(tables_text.stdout, "user_tables:");
    try expectContains(tables_text.stdout, "private_tables:");
    try expectContains(tables_text.stdout, "documents");
    try expectContains(tables_text.stdout, "_zova_objects");
    try std.testing.expect(std.mem.indexOf(u8, tables_text.stdout, "create table") == null);
    try std.testing.expect(std.mem.indexOf(u8, tables_text.stdout, "hello.txt") == null);

    var tables_json = try runCli(&.{ "zova", "tables", "--json", "--limit", "0", db_path });
    defer tables_json.deinit();
    try std.testing.expectEqual(@as(u8, 0), tables_json.code);
    var parsed_tables = try parseJson(tables_json.stdout);
    defer parsed_tables.deinit();
    try expectJsonString(parsed_tables.value.object, "command", "tables");
    try expectJsonArrayLen(parsed_tables.value.object, "user_tables", 0);
    try expectJsonArrayLen(parsed_tables.value.object, "private_tables", 0);
    try expectJsonBool(parsed_tables.value.object, "user_tables_truncated", true);
    try expectJsonBool(parsed_tables.value.object, "private_tables_truncated", true);
}

test "cli vector and table inspection usage failures use expected exit codes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-table-errors.zova");
    try createHealthyDatabase(db_path);

    const usage_cases = [_][]const []const u8{
        &.{ "zova", "vectors", "--wat", db_path },
        &.{ "zova", "vectors", "--json", "--json", db_path },
        &.{ "zova", "vector-collection", db_path },
        &.{ "zova", "vector-collection", db_path, "_zova_bad" },
        &.{ "zova", "vector-collection", db_path, "bad\xff" },
        &.{ "zova", "vector-collection", db_path, "docs", "extra" },
        &.{ "zova", "tables", "--limit", "101", db_path },
        &.{ "zova", "tables", db_path, "extra" },
    };

    for (usage_cases) |args| {
        var result = try runCli(args);
        defer result.deinit();
        try std.testing.expectEqual(@as(u8, 2), result.code);
    }

    var missing_collection = try runCli(&.{ "zova", "vector-collection", "--json", db_path, "missing" });
    defer missing_collection.deinit();
    try std.testing.expectEqual(@as(u8, 4), missing_collection.code);
    var missing_json = try parseJson(missing_collection.stderr);
    defer missing_json.deinit();
    try expectJsonString(missing_json.value.object, "command", "vector-collection");
}

test "cli check succeeds for healthy databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "healthy.zova");
    try createHealthyDatabase(db_path);

    var quick = try runCli(&.{ "zova", "check", db_path });
    defer quick.deinit();
    try std.testing.expectEqual(@as(u8, 0), quick.code);
    try expectContains(quick.stdout, "ok");

    var deep = try runCli(&.{ "zova", "check", "--deep", db_path });
    defer deep.deinit();
    try std.testing.expectEqual(@as(u8, 0), deep.code);
    try expectContains(deep.stdout, "deep_check: ok");
    try expectContains(deep.stdout, "loose_chunks:");
}

test "cli check json succeeds for healthy databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "check-json.zova");
    try createHealthyDatabase(db_path);

    var quick = try runCli(&.{ "zova", "check", "--json", db_path });
    defer quick.deinit();
    try std.testing.expectEqual(@as(u8, 0), quick.code);
    var quick_json = try parseJson(quick.stdout);
    defer quick_json.deinit();
    const quick_root = quick_json.value.object;
    try expectJsonInt(quick_root, "cli_json_version", 1);
    try expectJsonString(quick_root, "status", "ok");
    try expectJsonString(quick_root, "quick_check", "ok");
    try std.testing.expect(quick_root.get("deep_check") == null);

    var deep = try runCli(&.{ "zova", "check", "--json", "--deep", db_path });
    defer deep.deinit();
    try std.testing.expectEqual(@as(u8, 0), deep.code);
    var deep_json = try parseJson(deep.stdout);
    defer deep_json.deinit();
    const deep_root = deep_json.value.object;
    try expectJsonString(deep_root, "status", "ok");
    try expectJsonString(deep_root, "deep_check", "ok");
    try expectJsonObjectHasInt(deep_root, "checked", "objects");
    try expectJsonObjectHasInt(deep_root, "checked", "chunks");
    try expectJsonObjectHasInt(deep_root, "checked", "vectors");
    try expectJsonObjectHasInt(deep_root, "checked", "loose_chunks");
    try expectJsonInt(deep_root, "issue_count", 0);
    try expectJsonObjectHasInt(deep_root, "issue_counts", "object");
    try expectJsonObjectHasInt(deep_root, "issue_counts", "chunk");
    try expectJsonObjectHasInt(deep_root, "issue_counts", "vector");
    try expectJsonArrayLen(deep_root, "issues", 0);

    var reversed = try runCli(&.{ "zova", "check", "--deep", "--json", db_path });
    defer reversed.deinit();
    try std.testing.expectEqual(@as(u8, 0), reversed.code);
    var reversed_json = try parseJson(reversed.stdout);
    defer reversed_json.deinit();
    try expectJsonString(reversed_json.value.object, "deep_check", "ok");
}

test "cli doctor reports healthy databases in text and json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "doctor-healthy.zova");
    try createHealthyDatabase(db_path);

    var text = try runCli(&.{ "zova", "doctor", db_path });
    defer text.deinit();
    try std.testing.expectEqual(@as(u8, 0), text.code);
    try expectContains(text.stdout, "Zova doctor:");
    try expectContains(text.stdout, "status: ok");
    try expectContains(text.stdout, "quick_check: ok");
    try expectContains(text.stdout, "schema: ok");
    try expectContains(text.stdout, "objects_checked:");
    try expectContains(text.stdout, "chunks_checked:");
    try expectContains(text.stdout, "vectors_checked:");
    try expectContains(text.stdout, "user_tables:");
    try expectContains(text.stdout, "private_tables:");
    try expectContains(text.stdout, "suggested_actions:");
    try std.testing.expect(std.mem.indexOf(u8, text.stdout, "hello object") == null);
    try std.testing.expect(std.mem.indexOf(u8, text.stdout, "hidden chunk bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, text.stdout, "7.25") == null);

    var json = try runCli(&.{ "zova", "doctor", "--json", db_path });
    defer json.deinit();
    try std.testing.expectEqual(@as(u8, 0), json.code);
    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonInt(root, "cli_json_version", 1);
    try expectJsonString(root, "status", "ok");
    try expectJsonString(root, "command", "doctor");
    try expectJsonString(root, "source_path", db_path);
    try expectJsonObjectHasInt(root, "checked", "objects");
    try expectJsonObjectHasInt(root, "checked", "chunks");
    try expectJsonObjectHasInt(root, "checked", "vectors");
    try expectJsonInt(root, "issue_count", 0);
    try expectJsonObjectHasInt(root, "issue_counts", "object");
    try expectJsonObjectHasInt(root, "severity_counts", "error");
    try expectJsonArrayLen(root, "issues", 0);
    try expectJsonArray(root, "suggested_actions");
    try std.testing.expect(std.mem.indexOf(u8, json.stdout, "hello object") == null);
    try std.testing.expect(std.mem.indexOf(u8, json.stdout, "hidden chunk bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, json.stdout, "7.25") == null);

    var source_check = try runCli(&.{ "zova", "check", "--deep", db_path });
    defer source_check.deinit();
    try std.testing.expectEqual(@as(u8, 0), source_check.code);
}

test "cli doctor reports corruption with bounded json issues" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "doctor-corrupt.zova");
    try createHealthyDatabase(db_path);

    {
        var raw = try zova.sqlite.Database.open(db_path);
        defer raw.deinit();
        try raw.exec(
            \\update _zova_chunks
            \\set data = x'636f7272757074', size_bytes = 7
            \\where rowid = (select rowid from _zova_chunks limit 1);
            \\update _zova_vectors
            \\set "values" = x'0000c07f'
            \\where vector_id = 'doc-1';
        );
    }

    var limited = try runCli(&.{ "zova", "doctor", "--json", "--limit", "1", db_path });
    defer limited.deinit();
    try std.testing.expectEqual(@as(u8, 4), limited.code);
    var parsed = try parseJson(limited.stderr);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonString(root, "status", "needs_attention");
    try expectJsonString(root, "command", "doctor");
    try expectJsonObjectHasInt(root, "issue_counts", "chunk");
    try expectJsonObjectHasInt(root, "issue_counts", "vector");
    try expectJsonObjectHasInt(root, "severity_counts", "error");
    try expectJsonBool(root, "issues_truncated", true);
    try expectJsonArrayLen(root, "issues", 1);
    try expectJsonArray(root, "suggested_actions");
    try std.testing.expect(std.mem.indexOf(u8, limited.stderr, "zova salvage --dry-run") != null);
    try std.testing.expect(std.mem.indexOf(u8, limited.stderr, "corrupt") != null);
    try std.testing.expect(std.mem.indexOf(u8, limited.stderr, "hidden chunk bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, limited.stderr, "7.25") == null);

    var zero = try runCli(&.{ "zova", "doctor", "--json", "--limit", "0", db_path });
    defer zero.deinit();
    try std.testing.expectEqual(@as(u8, 4), zero.code);
    var zero_json = try parseJson(zero.stderr);
    defer zero_json.deinit();
    const zero_root = zero_json.value.object;
    try expectJsonBool(zero_root, "issues_truncated", true);
    try expectJsonArrayLen(zero_root, "issues", 0);
    const issue_count = zero_root.get("issue_count") orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.integer, std.meta.activeTag(issue_count));
    try std.testing.expect(issue_count.integer > 0);

    var zero_text = try runCli(&.{ "zova", "doctor", "--limit", "0", db_path });
    defer zero_text.deinit();
    try std.testing.expectEqual(@as(u8, 4), zero_text.code);
    try expectContains(zero_text.stderr, "issue_count:");
    try expectContains(zero_text.stderr, "no issue examples shown");
    try std.testing.expect(std.mem.indexOf(u8, zero_text.stderr, "issues:\n  none") == null);
}

test "cli salvage dry-run reports healthy recoverability in text and json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "salvage-healthy.zova");
    try createHealthyDatabase(db_path);

    var text = try runCli(&.{ "zova", "salvage", "--dry-run", db_path });
    defer text.deinit();
    try std.testing.expectEqual(@as(u8, 0), text.code);
    try expectContains(text.stdout, "Zova salvage dry-run:");
    try expectContains(text.stdout, "status: ok");
    try expectContains(text.stdout, "dry_run: true");
    try expectContains(text.stdout, "will_write_destination: false");
    try expectContains(text.stdout, "recoverability: recoverable");
    try expectContains(text.stdout, "recoverable_user_tables:");
    try expectContains(text.stdout, "skipped_objects: 0");
    try expectContains(text.stdout, "issues:\n  none");
    try std.testing.expect(std.mem.indexOf(u8, text.stdout, "hello object") == null);
    try std.testing.expect(std.mem.indexOf(u8, text.stdout, "hidden chunk bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, text.stdout, "7.25") == null);

    var json = try runCli(&.{ "zova", "salvage", "--dry-run", "--json", db_path });
    defer json.deinit();
    try std.testing.expectEqual(@as(u8, 0), json.code);
    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonInt(root, "cli_json_version", 1);
    try expectJsonString(root, "status", "ok");
    try expectJsonString(root, "command", "salvage");
    try expectJsonBool(root, "dry_run", true);
    try expectJsonBool(root, "will_write_destination", false);
    try expectJsonString(root, "source_path", db_path);
    try expectJsonString(root, "recoverability", "recoverable");
    try expectJsonObjectHasInt(root, "recoverable", "user_tables");
    try expectJsonObjectHasInt(root, "recoverable", "objects");
    try expectJsonObjectHasInt(root, "recoverable", "chunks");
    try expectJsonObjectHasInt(root, "recoverable", "vector_collections");
    try expectJsonObjectHasInt(root, "recoverable", "vectors");
    try expectJsonObjectHasInt(root, "skipped", "objects");
    try expectJsonInt(root, "issue_count", 0);
    try expectJsonArrayLen(root, "issues", 0);
    try expectJsonArray(root, "suggested_actions");
    try std.testing.expect(std.mem.indexOf(u8, json.stdout, "hello object") == null);
    try std.testing.expect(std.mem.indexOf(u8, json.stdout, "hidden chunk bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, json.stdout, "7.25") == null);

    var source_check = try runCli(&.{ "zova", "check", "--deep", db_path });
    defer source_check.deinit();
    try std.testing.expectEqual(@as(u8, 0), source_check.code);
}

test "cli salvage dry-run reports corrupt recoverability with bounded issues" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "salvage-corrupt.zova");
    try createHealthyDatabase(db_path);

    {
        var raw = try zova.sqlite.Database.open(db_path);
        defer raw.deinit();
        try raw.exec(
            \\update _zova_chunks
            \\set data = x'636f7272757074', size_bytes = 7
            \\where rowid = (select rowid from _zova_chunks limit 1);
            \\update _zova_vectors
            \\set "values" = x'0000c07f'
            \\where vector_id = 'doc-1';
        );
    }

    var limited = try runCli(&.{ "zova", "salvage", "--dry-run", "--json", "--limit", "1", db_path });
    defer limited.deinit();
    try std.testing.expectEqual(@as(u8, 4), limited.code);
    var parsed = try parseJson(limited.stderr);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonString(root, "status", "needs_attention");
    try expectJsonString(root, "command", "salvage");
    try expectJsonBool(root, "dry_run", true);
    try expectJsonBool(root, "will_write_destination", false);
    try expectJsonString(root, "recoverability", "partially_recoverable");
    try expectJsonObjectHasInt(root, "issue_counts", "chunk");
    try expectJsonObjectHasInt(root, "issue_counts", "vector");
    try expectJsonObjectHasInt(root, "skipped", "chunks");
    try expectJsonObjectHasInt(root, "skipped", "vectors");
    try expectJsonBool(root, "issues_truncated", true);
    try expectJsonArrayLen(root, "issues", 1);
    try expectJsonArray(root, "suggested_actions");
    try std.testing.expect(std.mem.indexOf(u8, limited.stderr, "corrupt") != null);
    try std.testing.expect(std.mem.indexOf(u8, limited.stderr, "hidden chunk bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, limited.stderr, "7.25") == null);

    var zero = try runCli(&.{ "zova", "salvage", "--dry-run", "--json", "--limit", "0", db_path });
    defer zero.deinit();
    try std.testing.expectEqual(@as(u8, 4), zero.code);
    var zero_json = try parseJson(zero.stderr);
    defer zero_json.deinit();
    const zero_root = zero_json.value.object;
    try expectJsonBool(zero_root, "issues_truncated", true);
    try expectJsonArrayLen(zero_root, "issues", 0);
    const issue_count = zero_root.get("issue_count") orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.integer, std.meta.activeTag(issue_count));
    try std.testing.expect(issue_count.integer > 0);
}

test "cli salvage dry-run counts missing chunks as skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "salvage-missing-chunks.zova");
    try createHealthyDatabase(db_path);

    {
        var raw = try zova.sqlite.Database.open(db_path);
        defer raw.deinit();
        try raw.exec("delete from _zova_chunks");
    }

    var result = try runCli(&.{ "zova", "salvage", "--dry-run", "--json", "--limit", "0", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 4), result.code);
    var parsed = try parseJson(result.stderr);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonString(root, "command", "salvage");
    try expectJsonString(root, "status", "needs_attention");
    try std.testing.expect(try jsonObjectInt(root, "issue_counts", "chunk") > 0);
    try std.testing.expect(try jsonObjectInt(root, "skipped", "chunks") > 0);
    try expectJsonArrayLen(root, "issues", 0);
    try expectJsonBool(root, "issues_truncated", true);
}

test "cli salvage recovers trgm extension storage without leaking indexed text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "salvage-trgm-source.zova");
    const sensitive_text = "private indexed phrase pineapple midnight";
    {
        var db = try zova.Database.create(source_path);
        defer db.deinit();
        try db.installExtension("trgm");
        try db.exec("select zova_trgm_create_index('docs')");
        var put = try db.prepare("select zova_trgm_put('docs', 'doc:secret', 'record', 'notes', '1', ?)");
        defer put.deinit();
        try put.bindText(1, sensitive_text);
        try std.testing.expectEqual(zova.sqlite.Step.row, try put.step());
    }

    var dry_run = try runCli(&.{ "zova", "salvage", "--dry-run", "--json", source_path });
    defer dry_run.deinit();
    try std.testing.expectEqual(@as(u8, 0), dry_run.code);
    var dry_json = try parseJson(dry_run.stdout);
    defer dry_json.deinit();
    const dry_root = dry_json.value.object;
    try std.testing.expectEqual(@as(i64, 1), try jsonObjectInt(dry_root, "recoverable", "extensions"));
    try std.testing.expect((try jsonObjectInt(dry_root, "recoverable", "extension_private_objects")) > 0);
    try std.testing.expectEqual(@as(i64, 0), try jsonObjectInt(dry_root, "skipped", "extensions"));
    try std.testing.expectEqual(@as(i64, 0), try jsonObjectInt(dry_root, "skipped", "extension_private_objects"));
    try std.testing.expect(std.mem.indexOf(u8, dry_run.stdout, sensitive_text) == null);
    try std.testing.expect(std.mem.indexOf(u8, dry_run.stdout, "create table") == null);

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "salvage-trgm-destination.zova");
    var salvage = try runCli(&.{ "zova", "salvage", "--json", source_path, dest_path });
    defer salvage.deinit();
    try std.testing.expectEqual(@as(u8, 0), salvage.code);
    var salvage_json = try parseJson(salvage.stdout);
    defer salvage_json.deinit();
    const root = salvage_json.value.object;
    try expectJsonBool(root, "destination_verified", true);
    try std.testing.expectEqual(@as(i64, 1), try jsonObjectInt(root, "copied", "extensions"));
    try std.testing.expect((try jsonObjectInt(root, "copied", "extension_private_objects")) > 0);
    try std.testing.expectEqual(@as(i64, 0), try jsonObjectInt(root, "skipped", "extensions"));
    try std.testing.expectEqual(@as(i64, 0), try jsonObjectInt(root, "skipped", "extension_private_objects"));
    try std.testing.expect(std.mem.indexOf(u8, salvage.stdout, sensitive_text) == null);
    try std.testing.expect(std.mem.indexOf(u8, salvage.stdout, "create table") == null);

    var extension_list = try runCli(&.{ "zova", "extension", "list", "--json", dest_path });
    defer extension_list.deinit();
    try std.testing.expectEqual(@as(u8, 0), extension_list.code);
    var list_json = try parseJson(extension_list.stdout);
    defer list_json.deinit();
    const extensions = list_json.value.object.get("extensions") orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.array, std.meta.activeTag(extensions));
    try std.testing.expectEqual(@as(usize, 1), extensions.array.items.len);
    try expectJsonString(extensions.array.items[0].object, "name", "trgm");

    var deep = try runCli(&.{ "zova", "check", "--deep", dest_path });
    defer deep.deinit();
    try std.testing.expectEqual(@as(u8, 0), deep.code);
}

test "cli salvage skips unavailable extension storage through inspection fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "salvage-unavailable-extension-source.zova");
    try createUnavailableExtensionFixture(source_path);
    {
        var raw = try zova.sqlite.Database.open(source_path);
        defer raw.deinit();
        try raw.exec("create table notes (id integer primary key, body text); insert into notes (body) values ('keep me')");
    }

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "salvage-unavailable-extension-destination.zova");
    var salvage = try runCli(&.{ "zova", "salvage", "--json", source_path, dest_path });
    defer salvage.deinit();
    try std.testing.expectEqual(@as(u8, 0), salvage.code);
    var parsed = try parseJson(salvage.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonBool(root, "destination_verified", true);
    try std.testing.expectEqual(@as(i64, 0), try jsonObjectInt(root, "copied", "extensions"));
    try std.testing.expectEqual(@as(i64, 1), try jsonObjectInt(root, "skipped", "extensions"));
    try std.testing.expect((try jsonObjectInt(root, "skipped", "extension_private_objects")) > 0);

    var extension_list = try runCli(&.{ "zova", "extension", "list", "--json", dest_path });
    defer extension_list.deinit();
    try std.testing.expectEqual(@as(u8, 0), extension_list.code);
    var list_json = try parseJson(extension_list.stdout);
    defer list_json.deinit();
    try expectJsonArrayLen(list_json.value.object, "extensions", 0);

    var raw_dest = try zova.sqlite.Database.open(dest_path);
    defer raw_dest.deinit();
    try std.testing.expectEqual(@as(i64, 1), try countRawRows(&raw_dest, "select count(*) from notes"));
    try std.testing.expectEqual(@as(i64, 0), try countRawRows(&raw_dest, "select count(*) from sqlite_master where name like '_zova_ext_test_%'"));
}

test "cli salvage copies healthy database into verified destination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "salvage-source.zova");
    try createHealthyDatabase(source_path);
    try addRichUserSqlFixture(source_path);
    {
        var source = try zova.Database.open(source_path);
        defer source.deinit();
        try source.createGraph("app");
        try source.putGraphNode(.{ .graph_name = "app", .node_id = "message:1", .kind = "message", .target_type = .record, .target_ref = "notes:1" });
        try source.putGraphNode(.{ .graph_name = "app", .node_id = "attachment:1", .kind = "attachment", .target_type = .external, .target_ref = "attachment:1" });
        try source.putGraphEdge(.{ .graph_name = "app", .from_node_id = "message:1", .edge_type = "has_attachment", .to_node_id = "attachment:1" });
    }

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "salvage-destination.zova");

    var result = try runCli(&.{ "zova", "salvage", "--json", source_path, dest_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonString(root, "status", "ok");
    try expectJsonString(root, "command", "salvage");
    try expectJsonBool(root, "dry_run", false);
    try expectJsonBool(root, "will_write_destination", true);
    try expectJsonString(root, "source_path", source_path);
    try expectJsonString(root, "destination_path", dest_path);
    try expectJsonBool(root, "destination_verified", true);
    try expectJsonObjectHasInt(root, "copied", "user_tables");
    try std.testing.expect((try jsonObjectInt(root, "copied", "user_schema_objects")) > 0);
    try std.testing.expect((try jsonObjectInt(root, "copied", "user_rows")) > 0);
    try expectJsonObjectHasInt(root, "copied", "objects");
    try expectJsonObjectHasInt(root, "copied", "vectors");
    try std.testing.expect((try jsonObjectInt(root, "copied", "graphs")) > 0);
    try std.testing.expect((try jsonObjectInt(root, "copied", "graph_nodes")) > 0);
    try std.testing.expect((try jsonObjectInt(root, "copied", "graph_edges")) > 0);
    try expectJsonObjectHasInt(root, "skipped", "objects");
    try expectJsonObjectHasInt(root, "skipped", "user_schema_objects");
    try std.testing.expectEqual(@as(i64, 0), try jsonObjectInt(root, "skipped", "user_rows"));
    try expectJsonArrayLen(root, "issues", 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello object") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hidden chunk bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "secret blob value") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "7.25") == null);

    var deep = try runCli(&.{ "zova", "check", "--deep", dest_path });
    defer deep.deinit();
    try std.testing.expectEqual(@as(u8, 0), deep.code);
    try expectHealthyCopy(dest_path);
    try expectRichUserSqlFixture(dest_path);
    {
        var destination = try zova.Database.open(dest_path);
        defer destination.deinit();
        try std.testing.expect(try destination.hasGraph("app"));
        try std.testing.expect(try destination.hasGraphEdge("app", "message:1", "has_attachment", "attachment:1"));
    }
}

test "cli salvage copies valid graph data and skips invalid graph targets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "salvage-graph-source.zova");
    try createHealthyDatabase(source_path);

    {
        var source = try zova.Database.open(source_path);
        defer source.deinit();
        try source.createGraph("app");
        try source.putGraphNode(.{ .graph_name = "app", .node_id = "message:1", .kind = "message", .target_type = .record, .target_ref = "notes:1" });
        try source.putGraphNode(.{ .graph_name = "app", .node_id = "object:missing", .kind = "attachment", .target_type = .object, .target_ref = "0000000000000000000000000000000000000000000000000000000000000000" });
        try source.putGraphEdge(.{ .graph_name = "app", .from_node_id = "message:1", .edge_type = "has_attachment", .to_node_id = "object:missing" });
    }

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "salvage-graph-destination.zova");

    var result = try runCli(&.{ "zova", "salvage", "--json", source_path, dest_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonString(root, "status", "ok");
    try expectJsonBool(root, "destination_verified", true);
    try std.testing.expect((try jsonObjectInt(root, "issue_counts", "graph")) > 0);
    try std.testing.expect((try jsonObjectInt(root, "copied", "graphs")) > 0);
    try std.testing.expect((try jsonObjectInt(root, "copied", "graph_nodes")) > 0);

    var deep = try runCli(&.{ "zova", "check", "--deep", dest_path });
    defer deep.deinit();
    try std.testing.expectEqual(@as(u8, 0), deep.code);

    var destination = try zova.Database.open(dest_path);
    defer destination.deinit();
    try std.testing.expect(try destination.hasGraph("app"));
    try std.testing.expect(try destination.hasGraphNode("app", "message:1"));
    try std.testing.expect(!try destination.hasGraphNode("app", "object:missing"));
    try std.testing.expect(!try destination.hasGraphEdge("app", "message:1", "has_attachment", "object:missing"));
}

test "cli salvage reports skipped user rows without printing values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "salvage-row-skip-source.zova");
    try createHealthyDatabase(source_path);

    {
        var db = try zova.Database.open(source_path);
        defer db.deinit();
        try db.exec(
            \\create table generated_rows (
            \\  id integer primary key,
            \\  value text not null,
            \\  value_len integer generated always as (length(value)) stored
            \\);
            \\insert into generated_rows (value) values ('generated-secret-row-value');
        );
    }

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "salvage-row-skip-destination.zova");

    var result = try runCli(&.{ "zova", "salvage", "--json", source_path, dest_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonString(root, "status", "ok");
    try expectJsonBool(root, "destination_verified", true);
    try std.testing.expect((try jsonObjectInt(root, "skipped", "user_tables")) > 0);
    try std.testing.expect((try jsonObjectInt(root, "skipped", "user_rows")) > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "generated-secret-row-value") == null);

    var deep = try runCli(&.{ "zova", "check", "--deep", dest_path });
    defer deep.deinit();
    try std.testing.expectEqual(@as(u8, 0), deep.code);
}

test "cli salvage rejects invalid destinations without overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "salvage-policy-source.zova");
    try createHealthyDatabase(source_path);

    var existing_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const existing_path = try testingDbPath(&existing_buffer, tmp.sub_path[0..], "salvage-existing.zova");
    try createHealthyDatabase(existing_path);

    var existing = try runCli(&.{ "zova", "salvage", source_path, existing_path });
    defer existing.deinit();
    try std.testing.expectEqual(@as(u8, 4), existing.code);
    try expectContains(existing.stderr, "salvage failed");

    var invalid_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const invalid_path = try testingDbPath(&invalid_buffer, tmp.sub_path[0..], "salvage-destination.db");
    var invalid = try runCli(&.{ "zova", "salvage", source_path, invalid_path });
    defer invalid.deinit();
    try std.testing.expectEqual(@as(u8, 2), invalid.code);
    try expectContains(invalid.stderr, "destination");
}

test "cli salvage skips corrupt objects and preserves readable sql and vectors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "salvage-corrupt-source.zova");
    try createHealthyDatabase(source_path);
    try addRichUserSqlFixture(source_path);

    {
        var raw = try zova.sqlite.Database.open(source_path);
        defer raw.deinit();
        try raw.exec("delete from _zova_chunks");
    }

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "salvage-corrupt-destination.zova");

    var result = try runCli(&.{ "zova", "salvage", "--json", "--limit", "1", source_path, dest_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonString(root, "status", "ok");
    try expectJsonString(root, "recoverability", "partially_recoverable");
    try expectJsonBool(root, "destination_verified", true);
    try std.testing.expect(try jsonObjectInt(root, "skipped", "objects") > 0);
    try std.testing.expect(try jsonObjectInt(root, "skipped", "chunks") > 0);
    try expectJsonBool(root, "issues_truncated", true);
    try expectJsonArrayLen(root, "issues", 1);

    var deep = try runCli(&.{ "zova", "check", "--deep", dest_path });
    defer deep.deinit();
    try std.testing.expectEqual(@as(u8, 0), deep.code);
    try expectRichUserSqlFixture(dest_path);

    var dest = try zova.Database.open(dest_path);
    defer dest.deinit();
    var results = try dest.searchVectors(std.testing.allocator, "docs", .{ .f32 = &.{ 7.25, 8.5 } }, 1);
    defer results.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("doc-1", results.items[0].id);
}

test "cli salvage skips object hash mismatches and verifies destination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "salvage-object-hash-source.zova");
    try createHealthyDatabase(source_path);

    {
        var raw = try zova.sqlite.Database.open(source_path);
        defer raw.deinit();
        const original_id = zova.objectId("hello object");
        const wrong_id = zova.objectId("not hello object");

        var update_object = try raw.prepare("update _zova_objects set object_id = ? where object_id = ?");
        defer update_object.deinit();
        try update_object.bindBlob(1, &wrong_id);
        try update_object.bindBlob(2, &original_id);
        try std.testing.expectEqual(zova.sqlite.Step.done, try update_object.step());

        var update_manifest = try raw.prepare("update _zova_object_chunks set object_id = ? where object_id = ?");
        defer update_manifest.deinit();
        try update_manifest.bindBlob(1, &wrong_id);
        try update_manifest.bindBlob(2, &original_id);
        try std.testing.expectEqual(zova.sqlite.Step.done, try update_manifest.step());
    }

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "salvage-object-hash-destination.zova");

    var result = try runCli(&.{ "zova", "salvage", "--json", source_path, dest_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonString(root, "status", "ok");
    try expectJsonString(root, "recoverability", "partially_recoverable");
    try expectJsonBool(root, "destination_verified", true);
    try std.testing.expect((try jsonObjectInt(root, "issue_counts", "object")) > 0);
    try std.testing.expect((try jsonObjectInt(root, "skipped", "objects")) > 0);

    var deep = try runCli(&.{ "zova", "check", "--deep", dest_path });
    defer deep.deinit();
    try std.testing.expectEqual(@as(u8, 0), deep.code);
}

test "cli salvage skips corrupt loose chunks and keeps valid data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "salvage-loose-source.zova");
    try createHealthyDatabase(source_path);

    {
        var raw = try zova.sqlite.Database.open(source_path);
        defer raw.deinit();
        const loose_hash = zova.objectChunkId("hidden chunk bytes");
        var corrupt_loose = try raw.prepare("update _zova_chunks set data = x'626164', size_bytes = 3 where chunk_hash = ?");
        defer corrupt_loose.deinit();
        try corrupt_loose.bindBlob(1, &loose_hash);
        try std.testing.expectEqual(zova.sqlite.Step.done, try corrupt_loose.step());
    }

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "salvage-loose-destination.zova");

    var result = try runCli(&.{ "zova", "salvage", "--json", source_path, dest_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonString(root, "status", "ok");
    try expectJsonBool(root, "destination_verified", true);
    try std.testing.expect((try jsonObjectInt(root, "issue_counts", "chunk")) > 0);
    try std.testing.expect((try jsonObjectInt(root, "skipped", "chunks")) > 0);

    var deep = try runCli(&.{ "zova", "check", "--deep", dest_path });
    defer deep.deinit();
    try std.testing.expectEqual(@as(u8, 0), deep.code);

    var source_deep = try runCli(&.{ "zova", "check", "--deep", source_path });
    defer source_deep.deinit();
    try std.testing.expectEqual(@as(u8, 4), source_deep.code);

    var dest = try zova.Database.open(dest_path);
    defer dest.deinit();
    try std.testing.expectError(error.ObjectChunkNotFound, dest.getObjectChunk(std.testing.allocator, zova.objectChunkId("hidden chunk bytes")));
    var object = try dest.getObject(std.testing.allocator, zova.objectId("hello object"));
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello object", object.bytes);
}

test "cli salvage skips cosine zero stored vectors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "salvage-cosine-source.zova");
    try createHealthyDatabase(source_path);

    {
        var db = try zova.Database.open(source_path);
        defer db.deinit();
        try db.createVectorCollection("cosines", .{ .dimensions = 2, .metric = .cosine });
        try db.putVector("cosines", "valid", .{ .f32 = &.{ 1.0, 0.0 } });
    }
    {
        var raw = try zova.sqlite.Database.open(source_path);
        defer raw.deinit();
        try raw.exec("insert into _zova_vectors (collection_key, vector_id, \"values\", norm_squared) values ((select collection_key from _zova_vector_collections where name='cosines'), 'zero', x'0000000000000000', 0)");
    }

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "salvage-cosine-destination.zova");

    var result = try runCli(&.{ "zova", "salvage", "--json", source_path, dest_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonString(root, "status", "ok");
    try expectJsonBool(root, "destination_verified", true);
    try std.testing.expect((try jsonObjectInt(root, "issue_counts", "vector")) > 0);
    try std.testing.expect((try jsonObjectInt(root, "skipped", "vectors")) > 0);

    var dest = try zova.Database.open(dest_path);
    defer dest.deinit();
    try std.testing.expect(try dest.hasVector("cosines", "valid"));
    try std.testing.expect(!try dest.hasVector("cosines", "zero"));
    var results = try dest.searchVectors(std.testing.allocator, "cosines", .{ .f32 = &.{ 1.0, 0.0 } }, 5);
    defer results.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("valid", results.items[0].id);
}

test "cli check reports healthy converted database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var sqlite_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const sqlite_path = try testingDbPath(&sqlite_path_buffer, tmp.sub_path[0..], "source.db");
    {
        var raw = try zova.sqlite.Database.open(sqlite_path);
        defer raw.deinit();
        try raw.exec(
            \\create table notes (id integer primary key, body text not null);
            \\insert into notes (body) values ('kept as sql');
        );
    }

    var zova_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const zova_path = try testingDbPath(&zova_path_buffer, tmp.sub_path[0..], "converted.zova");
    try zova.convertSqliteToZova(sqlite_path, zova_path);

    {
        var db = try zova.Database.open(zova_path);
        defer db.deinit();
        _ = try db.putObject("converted object");
        try db.createVectorCollection("converted", .{ .dimensions = 2, .metric = .l2 });
        try db.putVector("converted", "note-1", .{ .f32 = &.{ 3.0, 4.0 } });
    }

    var info = try runCli(&.{ "zova", "info", zova_path });
    defer info.deinit();
    try std.testing.expectEqual(@as(u8, 0), info.code);
    try expectContains(info.stdout, "user_tables: 1");

    var check = try runCli(&.{ "zova", "check", "--deep", zova_path });
    defer check.deinit();
    try std.testing.expectEqual(@as(u8, 0), check.code);
    try expectContains(check.stdout, "deep_check: ok");

    var stats = try runCli(&.{ "zova", "stats", "--json", zova_path });
    defer stats.deinit();
    try std.testing.expectEqual(@as(u8, 0), stats.code);
    var stats_json = try parseJson(stats.stdout);
    defer stats_json.deinit();
    const stats_root = stats_json.value.object;
    try expectJsonObjectHasInt(stats_root, "tables", "user");
    try expectJsonObjectHasInt(stats_root, "objects", "count");
    try expectJsonObjectHasInt(stats_root, "vectors", "rows");
}

test "cli open failures return exit code 3" {
    var result = try runCli(&.{ "zova", "info", "missing.zova" });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 3), result.code);
    try expectContains(result.stderr, "open failed");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const sqlite_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "plain.db");
    {
        var raw = try zova.sqlite.Database.open(sqlite_path);
        defer raw.deinit();
        try raw.exec("create table plain (id integer primary key)");
    }

    var non_zova = try runCli(&.{ "zova", "info", sqlite_path });
    defer non_zova.deinit();
    try std.testing.expectEqual(@as(u8, 3), non_zova.code);
    try expectContains(non_zova.stderr, "open failed");

    var missing_doctor = try runCli(&.{ "zova", "doctor", "missing.zova" });
    defer missing_doctor.deinit();
    try std.testing.expectEqual(@as(u8, 3), missing_doctor.code);
    try expectContains(missing_doctor.stderr, "open failed");

    var non_zova_doctor = try runCli(&.{ "zova", "doctor", "--json", sqlite_path });
    defer non_zova_doctor.deinit();
    try std.testing.expectEqual(@as(u8, 3), non_zova_doctor.code);
    var doctor_json = try parseJson(non_zova_doctor.stderr);
    defer doctor_json.deinit();
    try expectJsonString(doctor_json.value.object, "command", "doctor");
    try std.testing.expect(doctor_json.value.object.get("issue_count") == null);

    var missing_salvage = try runCli(&.{ "zova", "salvage", "--dry-run", "missing.zova" });
    defer missing_salvage.deinit();
    try std.testing.expectEqual(@as(u8, 3), missing_salvage.code);
    try expectContains(missing_salvage.stderr, "open failed");

    var non_zova_salvage = try runCli(&.{ "zova", "salvage", "--dry-run", "--json", sqlite_path });
    defer non_zova_salvage.deinit();
    try std.testing.expectEqual(@as(u8, 3), non_zova_salvage.code);
    var salvage_json = try parseJson(non_zova_salvage.stderr);
    defer salvage_json.deinit();
    try expectJsonString(salvage_json.value.object, "command", "salvage");

    var text_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const text_path = try testingDbPath(&text_path_buffer, tmp.sub_path[0..], "not-sqlite.zova");
    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.writeFile(io, .{ .sub_path = "not-sqlite.zova", .data = "not sqlite" });
    var non_sqlite_doctor = try runCli(&.{ "zova", "doctor", "--json", text_path });
    defer non_sqlite_doctor.deinit();
    try std.testing.expectEqual(@as(u8, 3), non_sqlite_doctor.code);
    var non_sqlite_doctor_json = try parseJson(non_sqlite_doctor.stderr);
    defer non_sqlite_doctor_json.deinit();
    try expectJsonString(non_sqlite_doctor_json.value.object, "command", "doctor");
    try std.testing.expect(non_sqlite_doctor_json.value.object.get("issue_count") == null);

    var non_sqlite_salvage = try runCli(&.{ "zova", "salvage", "--dry-run", "--json", text_path });
    defer non_sqlite_salvage.deinit();
    try std.testing.expectEqual(@as(u8, 3), non_sqlite_salvage.code);
    var non_sqlite_salvage_json = try parseJson(non_sqlite_salvage.stderr);
    defer non_sqlite_salvage_json.deinit();
    try expectJsonString(non_sqlite_salvage_json.value.object, "command", "salvage");
    try std.testing.expect(non_sqlite_salvage_json.value.object.get("issue_count") == null);
}

test "cli json mode preserves open and corruption exit codes" {
    var missing = try runCli(&.{ "zova", "info", "--json", "missing.zova" });
    defer missing.deinit();
    try std.testing.expectEqual(@as(u8, 3), missing.code);
    var missing_json = try parseJson(missing.stderr);
    defer missing_json.deinit();
    const missing_root = missing_json.value.object;
    try expectJsonInt(missing_root, "cli_json_version", 1);
    try expectJsonString(missing_root, "status", "error");
    try expectJsonString(missing_root, "command", "info");
    try std.testing.expect(missing_root.get("error") != null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "json-corrupt.zova");
    try createHealthyDatabase(db_path);

    {
        var db = try zova.Database.open(db_path);
        defer db.deinit();
        try db.exec("pragma foreign_keys = off");
        try db.exec("delete from _zova_chunks");
    }

    var corrupt = try runCli(&.{ "zova", "check", "--json", "--deep", db_path });
    defer corrupt.deinit();
    try std.testing.expectEqual(@as(u8, 4), corrupt.code);
    var corrupt_json = try parseJson(corrupt.stderr);
    defer corrupt_json.deinit();
    const corrupt_root = corrupt_json.value.object;
    try expectJsonInt(corrupt_root, "cli_json_version", 1);
    try expectJsonString(corrupt_root, "status", "error");
    try expectJsonString(corrupt_root, "command", "check");
    try expectJsonObjectHasInt(corrupt_root, "issue_counts", "object");
    try expectJsonArray(corrupt_root, "issues");
}

test "cli json flag usage errors return exit code 2" {
    var unknown_info = try runCli(&.{ "zova", "info", "--wat", "x.zova" });
    defer unknown_info.deinit();
    try std.testing.expectEqual(@as(u8, 2), unknown_info.code);

    var duplicate_info = try runCli(&.{ "zova", "info", "--json", "--json", "x.zova" });
    defer duplicate_info.deinit();
    try std.testing.expectEqual(@as(u8, 2), duplicate_info.code);

    var duplicate_check = try runCli(&.{ "zova", "check", "--json", "--json", "x.zova" });
    defer duplicate_check.deinit();
    try std.testing.expectEqual(@as(u8, 2), duplicate_check.code);

    var extra = try runCli(&.{ "zova", "check", "--json", "x.zova", "extra" });
    defer extra.deinit();
    try std.testing.expectEqual(@as(u8, 2), extra.code);

    const doctor_usage_cases = [_][]const []const u8{
        &.{ "zova", "doctor", "--json", "--json", "x.zova" },
        &.{ "zova", "doctor", "--limit", "--json", "x.zova" },
        &.{ "zova", "doctor", "--limit", "101", "x.zova" },
        &.{ "zova", "doctor", "--wat", "x.zova" },
        &.{ "zova", "doctor", "x.zova", "extra" },
        &.{ "zova", "doctor" },
    };
    for (doctor_usage_cases) |args| {
        var doctor_usage = try runCli(args);
        defer doctor_usage.deinit();
        try std.testing.expectEqual(@as(u8, 2), doctor_usage.code);
    }

    const salvage_usage_cases = [_][]const []const u8{
        &.{ "zova", "salvage", "x.zova" },
        &.{ "zova", "salvage", "--dry-run", "--dry-run", "x.zova" },
        &.{ "zova", "salvage", "--dry-run", "--json", "--json", "x.zova" },
        &.{ "zova", "salvage", "--dry-run", "--limit", "--json", "x.zova" },
        &.{ "zova", "salvage", "--dry-run", "--limit", "101", "x.zova" },
        &.{ "zova", "salvage", "--dry-run", "--wat", "x.zova" },
        &.{ "zova", "salvage", "--dry-run", "x.zova", "dest.zova" },
        &.{ "zova", "salvage", "--dry-run" },
    };
    for (salvage_usage_cases) |args| {
        var salvage_usage = try runCli(args);
        defer salvage_usage.deinit();
        try std.testing.expectEqual(@as(u8, 2), salvage_usage.code);
    }
}

test "cli deep check reports object corruption with exit code 4" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "corrupt.zova");
    try createHealthyDatabase(db_path);

    {
        var db = try zova.Database.open(db_path);
        defer db.deinit();
        try db.exec("pragma foreign_keys = off");
        try db.exec("delete from _zova_chunks");
    }

    var result = try runCli(&.{ "zova", "check", "--deep", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 4), result.code);
    try expectContains(result.stderr, "deep_check: failed");
    try expectContains(result.stderr, "issue_count:");
    try expectContains(result.stderr, "object_issues:");
}

test "cli deep check reports multiple structured issue categories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "multiple-issues.zova");
    try createHealthyDatabase(db_path);

    {
        var raw = try zova.sqlite.Database.open(db_path);
        defer raw.deinit();
        try raw.exec(
            \\update _zova_chunks
            \\set data = x'636f7272757074', size_bytes = 7
            \\where rowid = (select rowid from _zova_chunks limit 1);
            \\update _zova_vectors
            \\set "values" = x'0000c07f'
            \\where vector_id = 'doc-1';
        );
    }

    var result = try runCli(&.{ "zova", "check", "--json", "--deep", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 4), result.code);
    var parsed = try parseJson(result.stderr);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonString(root, "command", "check");
    try expectJsonString(root, "status", "error");
    try expectJsonObjectHasInt(root, "issue_counts", "chunk");
    try expectJsonObjectHasInt(root, "issue_counts", "vector");
    try expectJsonArray(root, "issues");
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "corrupt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "doc-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "hidden chunk bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "7.25") == null);
}

test "cli check fails invalid metadata and missing private schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var invalid_meta_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const invalid_meta_path = try testingDbPath(&invalid_meta_buffer, tmp.sub_path[0..], "invalid-meta.zova");
    try createHealthyDatabase(invalid_meta_path);
    {
        var raw = try zova.sqlite.Database.open(invalid_meta_path);
        defer raw.deinit();
        try raw.exec("update _zova_meta set value = 'wrong' where key = 'magic'");
    }

    var invalid_meta = try runCli(&.{ "zova", "check", invalid_meta_path });
    defer invalid_meta.deinit();
    try std.testing.expectEqual(@as(u8, 3), invalid_meta.code);
    try expectContains(invalid_meta.stderr, "open failed");

    var invalid_meta_doctor = try runCli(&.{ "zova", "doctor", "--json", invalid_meta_path });
    defer invalid_meta_doctor.deinit();
    try std.testing.expectEqual(@as(u8, 3), invalid_meta_doctor.code);
    var invalid_meta_doctor_json = try parseJson(invalid_meta_doctor.stderr);
    defer invalid_meta_doctor_json.deinit();
    try expectJsonString(invalid_meta_doctor_json.value.object, "command", "doctor");
    try std.testing.expect(invalid_meta_doctor_json.value.object.get("issue_count") == null);

    var invalid_meta_salvage = try runCli(&.{ "zova", "salvage", "--dry-run", "--json", invalid_meta_path });
    defer invalid_meta_salvage.deinit();
    try std.testing.expectEqual(@as(u8, 3), invalid_meta_salvage.code);
    var invalid_meta_salvage_json = try parseJson(invalid_meta_salvage.stderr);
    defer invalid_meta_salvage_json.deinit();
    try expectJsonString(invalid_meta_salvage_json.value.object, "command", "salvage");
    try std.testing.expect(invalid_meta_salvage_json.value.object.get("issue_count") == null);

    var unsupported_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const unsupported_path = try testingDbPath(&unsupported_buffer, tmp.sub_path[0..], "unsupported-format.zova");
    try createHealthyDatabase(unsupported_path);
    {
        var raw = try zova.sqlite.Database.open(unsupported_path);
        defer raw.deinit();
        try raw.exec("update _zova_meta set value = '999' where key = 'format_version'");
    }

    var unsupported_doctor = try runCli(&.{ "zova", "doctor", "--json", unsupported_path });
    defer unsupported_doctor.deinit();
    try std.testing.expectEqual(@as(u8, 3), unsupported_doctor.code);
    var unsupported_doctor_json = try parseJson(unsupported_doctor.stderr);
    defer unsupported_doctor_json.deinit();
    try expectJsonString(unsupported_doctor_json.value.object, "command", "doctor");
    try std.testing.expect(unsupported_doctor_json.value.object.get("issue_count") == null);

    var unsupported_salvage = try runCli(&.{ "zova", "salvage", "--dry-run", "--json", unsupported_path });
    defer unsupported_salvage.deinit();
    try std.testing.expectEqual(@as(u8, 3), unsupported_salvage.code);
    var unsupported_salvage_json = try parseJson(unsupported_salvage.stderr);
    defer unsupported_salvage_json.deinit();
    try expectJsonString(unsupported_salvage_json.value.object, "command", "salvage");
    try std.testing.expect(unsupported_salvage_json.value.object.get("issue_count") == null);

    var missing_schema_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing_schema_path = try testingDbPath(&missing_schema_buffer, tmp.sub_path[0..], "missing-schema.zova");
    try createHealthyDatabase(missing_schema_path);
    {
        var raw = try zova.sqlite.Database.open(missing_schema_path);
        defer raw.deinit();
        try raw.exec("drop table _zova_chunks");
    }

    var missing_schema = try runCli(&.{ "zova", "check", missing_schema_path });
    defer missing_schema.deinit();
    try std.testing.expectEqual(@as(u8, 3), missing_schema.code);
    try expectContains(missing_schema.stderr, "open failed");

    var missing_schema_doctor = try runCli(&.{ "zova", "doctor", "--json", missing_schema_path });
    defer missing_schema_doctor.deinit();
    try std.testing.expectEqual(@as(u8, 3), missing_schema_doctor.code);
    var missing_schema_doctor_json = try parseJson(missing_schema_doctor.stderr);
    defer missing_schema_doctor_json.deinit();
    try expectJsonString(missing_schema_doctor_json.value.object, "command", "doctor");
    try std.testing.expect(missing_schema_doctor_json.value.object.get("issue_count") == null);

    var missing_schema_salvage = try runCli(&.{ "zova", "salvage", "--dry-run", "--json", missing_schema_path });
    defer missing_schema_salvage.deinit();
    try std.testing.expectEqual(@as(u8, 3), missing_schema_salvage.code);
    var missing_schema_salvage_json = try parseJson(missing_schema_salvage.stderr);
    defer missing_schema_salvage_json.deinit();
    try expectJsonString(missing_schema_salvage_json.value.object, "command", "salvage");
    try std.testing.expect(missing_schema_salvage_json.value.object.get("issue_count") == null);
}

test "cli deep check reports full object hash mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "wrong-object-id.zova");
    {
        var db = try zova.Database.create(db_path);
        defer db.deinit();
        _ = try db.putObject("hello object");
    }

    {
        var raw = try zova.sqlite.Database.open(db_path);
        defer raw.deinit();
        const wrong_id = zova.objectId("not hello object");
        var update_object = try raw.prepare("update _zova_objects set object_id = ?");
        defer update_object.deinit();
        try update_object.bindBlob(1, &wrong_id);
        try std.testing.expectEqual(zova.sqlite.Step.done, try update_object.step());

        var update_manifest = try raw.prepare("update _zova_object_chunks set object_id = ?");
        defer update_manifest.deinit();
        try update_manifest.bindBlob(1, &wrong_id);
        try std.testing.expectEqual(zova.sqlite.Step.done, try update_manifest.step());
    }

    var result = try runCli(&.{ "zova", "check", "--deep", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 4), result.code);
    try expectContains(result.stderr, "object corruption");
}

test "cli deep check reports vector corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "bad-vector.zova");
    try createHealthyDatabase(db_path);

    {
        var raw = try zova.sqlite.Database.open(db_path);
        defer raw.deinit();
        try raw.exec("update _zova_vectors set \"values\" = x'0000803f' where vector_id = 'doc-1'");
    }

    var result = try runCli(&.{ "zova", "check", "--deep", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 4), result.code);
    try expectContains(result.stderr, "vector corruption");
}

test "cli deep check covers writer-created object and sql-introduced corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-and-corruption.zova");
    try createHealthyDatabase(db_path);

    var healthy = try runCli(&.{ "zova", "check", "--deep", db_path });
    defer healthy.deinit();
    try std.testing.expectEqual(@as(u8, 0), healthy.code);
    try expectContains(healthy.stdout, "objects_checked: 2");
    try expectContains(healthy.stdout, "vectors_checked: 1");
    try expectContains(healthy.stdout, "loose_chunks: 1");

    {
        var raw = try zova.sqlite.Database.open(db_path);
        defer raw.deinit();
        try raw.exec("update _zova_chunks set data = x'636f7272757074', size_bytes = 7 where rowid = (select rowid from _zova_chunks limit 1)");
    }

    var corrupt = try runCli(&.{ "zova", "check", "--deep", db_path });
    defer corrupt.deinit();
    try std.testing.expectEqual(@as(u8, 4), corrupt.code);
    try expectContains(corrupt.stderr, "object corruption");
}

const CliResult = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *CliResult) void {
        std.testing.allocator.free(self.stdout);
        std.testing.allocator.free(self.stderr);
    }
};

const ProcessResult = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *ProcessResult) void {
        std.testing.allocator.free(self.stdout);
        std.testing.allocator.free(self.stderr);
    }
};

fn runCli(args: []const []const u8) !CliResult {
    var stdout_buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const code = try cli.run(std.testing.allocator, args, &stdout_buffer.writer, &stderr_buffer.writer);
    return .{
        .code = code,
        .stdout = try std.testing.allocator.dupe(u8, stdout_buffer.written()),
        .stderr = try std.testing.allocator.dupe(u8, stderr_buffer.written()),
    };
}

fn runCliProcessInCwd(args: []const []const u8, cwd: []const u8) !CliResult {
    if (args.len == 0) return error.InvalidArguments;

    const allocator = std.testing.allocator;
    const exe_path = try absolutePathAlloc(cli.zova_exe_path);
    defer allocator.free(exe_path);

    const argv = try allocator.alloc([]const u8, args.len);
    defer allocator.free(argv);
    argv[0] = exe_path;
    @memcpy(argv[1..], args[1..]);

    var result = try runProcessForTestInCwd(argv, null, null, cwd);
    errdefer result.deinit();
    return .{
        .code = result.code,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn expectCliCode(result: *const CliResult, expected: u8) !void {
    if (result.code != expected) {
        std.debug.print(
            \\expected CLI exit code {d}, found {d}
            \\stdout:
            \\{s}
            \\stderr:
            \\{s}
            \\
        , .{ expected, result.code, result.stdout, result.stderr });
    }
    try std.testing.expectEqual(expected, result.code);
}

test "cli format reports text and json for all compatibility states" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = defaultIo();

    // current (fresh format 10)
    var current_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const current_path = try testingDbPath(&current_buffer, tmp.sub_path[0..], "format-current.zova");
    try createHealthyDatabase(current_path);

    // migratable (format 9 fixture copy)
    var migratable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const migratable_path = try testingDbPath(&migratable_buffer, tmp.sub_path[0..], "format-migratable.zova");
    try copyFixtureFile("tests/fixtures/format-9.zova", migratable_path);

    // unsupported_future (11) and unsupported_legacy (8) via synthetic
    var future_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const future_path = try testingDbPath(&future_buffer, tmp.sub_path[0..], "format-future.zova");
    try createSyntheticFormatDatabase(future_path, "11");

    var legacy_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const legacy_path = try testingDbPath(&legacy_buffer, tmp.sub_path[0..], "format-legacy.zova");
    try createSyntheticFormatDatabase(legacy_path, "8");

    // invalid (plain text)
    var invalid_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const invalid_path = try testingDbPath(&invalid_buffer, tmp.sub_path[0..], "format-invalid.zova");
    try tmp.dir.writeFile(io, .{ .sub_path = "format-invalid.zova", .data = "not sqlite" });

    const cases = [_]struct {
        path: [:0]const u8,
        expected_compat: []const u8,
        expected_source_format: ?i64,
        expected_action: []const u8,
    }{
        .{ .path = current_path, .expected_compat = "current", .expected_source_format = 10, .expected_action = "none" },
        .{ .path = migratable_path, .expected_compat = "migratable", .expected_source_format = 9, .expected_action = "run 'zova migrate <source> <destination>'" },
        .{ .path = future_path, .expected_compat = "unsupported_future", .expected_source_format = 11, .expected_action = "upgrade Zova" },
        .{ .path = legacy_path, .expected_compat = "unsupported_legacy", .expected_source_format = 8, .expected_action = "unsupported" },
        .{ .path = invalid_path, .expected_compat = "invalid", .expected_source_format = null, .expected_action = "unsupported" },
    };

    for (cases) |case| {
        // JSON golden
        var json = try runCli(&.{ "zova", "format", "--json", case.path });
        defer json.deinit();
        try std.testing.expectEqual(@as(u8, 0), json.code);
        var parsed = try parseJson(json.stdout);
        defer parsed.deinit();
        const root = parsed.value.object;
        try expectJsonInt(root, "cli_json_version", 1);
        try expectJsonString(root, "command", "format");
        try expectJsonString(root, "status", "ok");
        try expectJsonString(root, "source_path", case.path);
        if (case.expected_source_format) |expected| {
            try expectJsonInt(root, "source_format", expected);
        } else {
            const val = root.get("source_format") orelse return error.MissingJsonField;
            try std.testing.expectEqual(std.json.Value.null, std.meta.activeTag(val));
        }
        try expectJsonInt(root, "current_format", 10);
        try expectJsonInt(root, "minimum_migratable_format", 9);
        try expectJsonString(root, "compatibility", case.expected_compat);
        try expectJsonString(root, "recommended_action", case.expected_action);
        try std.testing.expect(std.mem.indexOf(u8, json.stdout, "_zova_") == null);
        try std.testing.expect(std.mem.indexOf(u8, json.stdout, "select") == null);

        // Text golden
        var text = try runCli(&.{ "zova", "format", case.path });
        defer text.deinit();
        try std.testing.expectEqual(@as(u8, 0), text.code);
        try expectContains(text.stdout, "source:");
        try expectContains(text.stdout, "current_format: 10");
        try expectContains(text.stdout, "minimum_migratable_format: 9");
        try expectContains(text.stdout, case.expected_compat);
        try expectContains(text.stdout, case.expected_action);
        if (case.expected_source_format) |expected| {
            var expected_line_buf: [64]u8 = undefined;
            const expected_line = try std.fmt.bufPrint(&expected_line_buf, "source_format: {d}", .{expected});
            try expectContains(text.stdout, expected_line);
        } else {
            try expectContains(text.stdout, "source_format: null");
        }
        try std.testing.expect(std.mem.indexOf(u8, text.stdout, "_zova_") == null);
    }
}

test "cli format argument errors are bounded" {
    const cases = [_]struct {
        args: []const []const u8,
        expect_json: bool,
    }{
        .{ .args = &.{ "zova", "format" }, .expect_json = false },
        .{ .args = &.{ "zova", "format", "--json", "a.zova", "extra" }, .expect_json = true },
        .{ .args = &.{ "zova", "format", "--json", "--json", "a.zova" }, .expect_json = true },
        .{ .args = &.{ "zova", "format", "--wat", "a.zova" }, .expect_json = false },
        .{ .args = &.{ "zova", "format", "--json", "--wat", "a.zova" }, .expect_json = true },
    };
    for (cases) |case| {
        var result = try runCli(case.args);
        defer result.deinit();
        try std.testing.expectEqual(@as(u8, 2), result.code);
        if (case.expect_json) {
            try std.testing.expect(result.stderr.len > 0);
            var parsed = try parseJson(result.stderr);
            defer parsed.deinit();
            try expectJsonString(parsed.value.object, "command", "format");
            try expectJsonString(parsed.value.object, "status", "error");
        } else {
            try expectContains(result.stderr, "usage error");
        }
    }
}

test "cli migrate migrates format-9 to current preserves source and verifies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "migrate-source.zova");
    try copyFixtureFile("tests/fixtures/format-9.zova", source_path);
    const before_hash = try fileSha256(source_path);

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "migrate-dest.zova");

    // JSON migrate
    var json = try runCli(&.{ "zova", "migrate", "--json", source_path, dest_path });
    defer json.deinit();
    try std.testing.expectEqual(@as(u8, 0), json.code);
    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonInt(root, "cli_json_version", 1);
    try expectJsonString(root, "command", "migrate");
    try expectJsonString(root, "status", "ok");
    try expectJsonString(root, "source_path", source_path);
    try expectJsonString(root, "destination_path", dest_path);
    try expectJsonInt(root, "source_format", 9);
    try expectJsonInt(root, "destination_format", 10);
    try expectJsonBool(root, "verified", true);
    const bound = root.get("bound_stores") orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.object, std.meta.activeTag(bound));
    // single file fixture has no bound stores
    const objects_val = bound.object.get("objects") orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.null, std.meta.activeTag(objects_val));
    try std.testing.expect(std.mem.indexOf(u8, json.stdout, "_zova_") == null);
    try std.testing.expect(std.mem.indexOf(u8, json.stdout, "select") == null);

    // source preserved
    const after_hash = try fileSha256(source_path);
    try std.testing.expectEqualSlices(u8, &before_hash, &after_hash);

    // dest is current and healthy
    var format = try runCli(&.{ "zova", "format", "--json", dest_path });
    defer format.deinit();
    try std.testing.expectEqual(@as(u8, 0), format.code);
    var format_json = try parseJson(format.stdout);
    defer format_json.deinit();
    try expectJsonString(format_json.value.object, "compatibility", "current");
    try expectJsonInt(format_json.value.object, "source_format", 10);

    var check = try runCli(&.{ "zova", "check", "--json", "--deep", dest_path });
    defer check.deinit();
    try std.testing.expectEqual(@as(u8, 0), check.code);
    var doctor = try runCli(&.{ "zova", "doctor", "--json", dest_path });
    defer doctor.deinit();
    try std.testing.expectEqual(@as(u8, 0), doctor.code);

    // text mode also works and is source-preserving for second dest
    var dest2_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest2_path = try testingDbPath(&dest2_buffer, tmp.sub_path[0..], "migrate-dest2.zova");
    var text = try runCli(&.{ "zova", "migrate", source_path, dest2_path });
    defer text.deinit();
    try std.testing.expectEqual(@as(u8, 0), text.code);
    try expectContains(text.stdout, "migrate: ok");
    try expectContains(text.stdout, "source_format: 9");
    try expectContains(text.stdout, "destination_format: 10");
    try expectContains(text.stdout, "verified: true");
    try std.testing.expect(std.mem.indexOf(u8, text.stdout, "_zova_") == null);
}

test "cli migrate argument and destination errors are bounded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "migrate-arg-source.zova");
    try copyFixtureFile("tests/fixtures/format-9.zova", source_path);

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "migrate-arg-dest.zova");

    // create existing dest
    try createHealthyDatabase(dest_path);

    const cases = [_]struct {
        args: []const []const u8,
        expect_json: bool,
        expected_code: u8,
    }{
        .{ .args = &.{ "zova", "migrate" }, .expect_json = false, .expected_code = 2 },
        .{ .args = &.{ "zova", "migrate", source_path }, .expect_json = false, .expected_code = 2 },
        .{ .args = &.{ "zova", "migrate", "--json", "--json", source_path, dest_path }, .expect_json = true, .expected_code = 2 },
        .{ .args = &.{ "zova", "migrate", "--no-verify", "--no-verify", source_path, dest_path }, .expect_json = false, .expected_code = 2 },
        .{ .args = &.{ "zova", "migrate", "--wat", source_path, dest_path }, .expect_json = false, .expected_code = 2 },
        .{ .args = &.{ "zova", "migrate", source_path, source_path }, .expect_json = false, .expected_code = 2 },
        .{ .args = &.{ "zova", "migrate", source_path, dest_path, "extra" }, .expect_json = false, .expected_code = 2 },
    };
    for (cases) |case| {
        var result = try runCli(case.args);
        defer result.deinit();
        try std.testing.expectEqual(case.expected_code, result.code);
        if (case.expect_json) {
            var parsed = try parseJson(result.stderr);
            defer parsed.deinit();
            try expectJsonString(parsed.value.object, "command", "migrate");
            try expectJsonString(parsed.value.object, "status", "error");
        } else {
            try expectContains(result.stderr, "usage error");
        }
        // ensure no destination was created for usage errors (first dest remains but no extra file)
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "_zova_") == null);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "_zova_") == null);
    }

    // existing destination must fail and not overwrite
    var existing_hash = try fileSha256(dest_path);
    var existing = try runCli(&.{ "zova", "migrate", "--json", source_path, dest_path });
    defer existing.deinit();
    try std.testing.expectEqual(@as(u8, 3), existing.code);
    var existing_json = try parseJson(existing.stderr);
    defer existing_json.deinit();
    try expectJsonString(existing_json.value.object, "command", "migrate");
    try std.testing.expect(existing_json.value.object.get("error") != null);
    const after_hash = try fileSha256(dest_path);
    try std.testing.expectEqualSlices(u8, &existing_hash, &after_hash);

    // missing parent directory
    var missing_parent_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing_parent_path = try std.fmt.bufPrintZ(&missing_parent_buffer, ".zig-cache/tmp/{s}/no_such_dir/dest.zova", .{tmp.sub_path});
    var missing_parent = try runCli(&.{ "zova", "migrate", source_path, missing_parent_path });
    defer missing_parent.deinit();
    try std.testing.expectEqual(@as(u8, 3), missing_parent.code);
}

test "cli migrate handles unsupported formats and no-verify" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // current format source -> NoMigrationPath
    var current_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const current_path = try testingDbPath(&current_buffer, tmp.sub_path[0..], "migrate-current.zova");
    try createHealthyDatabase(current_path);
    var current_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const current_dest = try testingDbPath(&current_dest_buffer, tmp.sub_path[0..], "migrate-current-dest.zova");
    var current = try runCli(&.{ "zova", "migrate", "--json", current_path, current_dest });
    defer current.deinit();
    try std.testing.expectEqual(@as(u8, 3), current.code);
    var current_json = try parseJson(current.stderr);
    defer current_json.deinit();
    try expectJsonString(current_json.value.object, "command", "migrate");
    try std.testing.expect(current_json.value.object.get("error") != null);
    try expectPathMissing(current_dest);

    // legacy (8) and future (11)
    var legacy_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const legacy_path = try testingDbPath(&legacy_buffer, tmp.sub_path[0..], "migrate-legacy.zova");
    try createSyntheticFormatDatabase(legacy_path, "8");
    var legacy_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const legacy_dest = try testingDbPath(&legacy_dest_buffer, tmp.sub_path[0..], "migrate-legacy-dest.zova");
    var legacy = try runCli(&.{ "zova", "migrate", "--json", legacy_path, legacy_dest });
    defer legacy.deinit();
    try std.testing.expectEqual(@as(u8, 3), legacy.code);
    var legacy_json = try parseJson(legacy.stderr);
    defer legacy_json.deinit();
    try expectJsonString(legacy_json.value.object, "command", "migrate");
    try expectPathMissing(legacy_dest);

    var future_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const future_path = try testingDbPath(&future_buffer, tmp.sub_path[0..], "migrate-future.zova");
    try createSyntheticFormatDatabase(future_path, "11");
    var future_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const future_dest = try testingDbPath(&future_dest_buffer, tmp.sub_path[0..], "migrate-future-dest.zova");
    var future = try runCli(&.{ "zova", "migrate", "--json", future_path, future_dest });
    defer future.deinit();
    try std.testing.expectEqual(@as(u8, 3), future.code);
    try expectPathMissing(future_dest);

    // --no-verify still migrates
    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "migrate-noverify-source.zova");
    try copyFixtureFile("tests/fixtures/format-9.zova", source_path);
    var noverify_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const noverify_dest = try testingDbPath(&noverify_dest_buffer, tmp.sub_path[0..], "migrate-noverify-dest.zova");
    var noverify = try runCli(&.{ "zova", "migrate", "--json", "--no-verify", source_path, noverify_dest });
    defer noverify.deinit();
    try std.testing.expectEqual(@as(u8, 0), noverify.code);
    var noverify_json = try parseJson(noverify.stdout);
    defer noverify_json.deinit();
    try expectJsonBool(noverify_json.value.object, "verified", false);
    try expectJsonInt(noverify_json.value.object, "source_format", 9);
    try expectJsonInt(noverify_json.value.object, "destination_format", 10);
    // no-verify destination still passes deep check (separate)
    var check = try runCli(&.{ "zova", "check", "--deep", noverify_dest });
    defer check.deinit();
    try std.testing.expectEqual(@as(u8, 0), check.code);
}

test "cli migrate reports derived bound stores accurately" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build a bound set in tmp like migration parity tests do
    var set_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const set_dir = try std.fmt.bufPrint(&set_dir_buffer, ".zig-cache/tmp/{s}/migrate-bound", .{tmp.sub_path});

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try std.fmt.bufPrintZ(&main_buffer, "{s}/main.zova", .{set_dir});
    var objects_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const objects_path = try std.fmt.bufPrintZ(&objects_buffer, "{s}/main.objects.zova", .{set_dir});
    var vectors_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const vectors_path = try std.fmt.bufPrintZ(&vectors_buffer, "{s}/main.vectors.zova", .{set_dir});
    var graphs_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const graphs_path = try std.fmt.bufPrintZ(&graphs_buffer, "{s}/main.graphs.zova", .{set_dir});

    try setupMigrateBoundSet(&tmp, set_dir, main_path, objects_path, vectors_path, graphs_path);

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try std.fmt.bufPrintZ(&dest_buffer, "{s}/dest.zova", .{set_dir});

    var result = try runCli(&.{ "zova", "migrate", "--json", main_path, dest_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonInt(root, "source_format", 9);
    try expectJsonInt(root, "destination_format", 10);
    const bound = root.get("bound_stores") orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.object, std.meta.activeTag(bound));

    const expected_objects = try std.fmt.allocPrint(std.testing.allocator, "{s}.objects.zova", .{dest_path[0 .. dest_path.len - ".zova".len]});
    defer std.testing.allocator.free(expected_objects);
    const expected_vectors = try std.fmt.allocPrint(std.testing.allocator, "{s}.vectors.zova", .{dest_path[0 .. dest_path.len - ".zova".len]});
    defer std.testing.allocator.free(expected_vectors);
    const expected_graphs = try std.fmt.allocPrint(std.testing.allocator, "{s}.graphs.zova", .{dest_path[0 .. dest_path.len - ".zova".len]});
    defer std.testing.allocator.free(expected_graphs);

    try expectJsonString(bound.object, "objects", expected_objects);
    try expectJsonString(bound.object, "vectors", expected_vectors);
    try expectJsonString(bound.object, "graphs", expected_graphs);

    // files actually exist and no private names leaked
    try expectFileExists(std.Io.Dir.cwd(), expected_objects);
    try expectFileExists(std.Io.Dir.cwd(), expected_vectors);
    try expectFileExists(std.Io.Dir.cwd(), expected_graphs);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "_zova_bound_stores") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "select") == null);

    // dest is healthy
    var check = try runCli(&.{ "zova", "check", "--deep", "--json", dest_path });
    defer check.deinit();
    try std.testing.expectEqual(@as(u8, 0), check.code);
}

test "cli migrate busy source is rejected without publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "migrate-busy-source.zova");
    try copyFixtureFile("tests/fixtures/format-9.zova", source_path);
    const before_hash = try fileSha256(source_path);

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "migrate-busy-dest.zova");

    // Hold a write lock on the source
    var lock = try zova.sqlite.Database.open(source_path);
    defer lock.deinit();
    try lock.exec("begin immediate");

    var json = try runCli(&.{ "zova", "migrate", "--json", source_path, dest_path });
    defer json.deinit();
    try std.testing.expectEqual(@as(u8, 3), json.code);
    var parsed = try parseJson(json.stderr);
    defer parsed.deinit();
    try expectJsonString(parsed.value.object, "command", "migrate");
    try expectJsonString(parsed.value.object, "status", "error");
    const err_val = parsed.value.object.get("error") orelse return error.MissingJsonField;
    const err_str = switch (err_val) {
        .string => |s| s,
        else => return error.MissingJsonField,
    };
    try std.testing.expect(std.mem.eql(u8, err_str, "Busy") or std.mem.eql(u8, err_str, "Locked"));
    try expectPathMissing(dest_path);
    const after_hash = try fileSha256(source_path);
    try std.testing.expectEqualSlices(u8, &before_hash, &after_hash);

    // text mode also reports busy without leaking private names
    var text_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const text_dest_path = try testingDbPath(&text_dest_buffer, tmp.sub_path[0..], "migrate-busy-dest-text.zova");
    var text = try runCli(&.{ "zova", "migrate", source_path, text_dest_path });
    defer text.deinit();
    try std.testing.expectEqual(@as(u8, 3), text.code);
    try std.testing.expect(std.mem.indexOf(u8, text.stderr, "Busy") != null or std.mem.indexOf(u8, text.stderr, "Locked") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.stderr, "_zova_") == null);
    try expectPathMissing(text_dest_path);
}

test "cli migrate verification failure is reported without publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "migrate-verify-source.zova");
    try copyFixtureFile("tests/fixtures/format-9.zova", source_path);
    const before_hash = try fileSha256(source_path);

    // Corrupt a chunk relation in the migratable source so staged copy fails verification
    {
        var raw = try zova.sqlite.Database.open(source_path);
        defer raw.deinit();
        // Corrupt first chunk's data but keep size_bytes, so hash mismatch -> verification fails
        try raw.exec("update _zova_chunks set data = randomblob(size_bytes) where rowid = (select rowid from _zova_chunks limit 1)");
    }
    // Ensure probe still sees migratable
    {
        const info = try zova.probeDatabaseFormat(source_path);
        try std.testing.expectEqual(@as(u32, 9), info.format_version);
        try std.testing.expectEqual(zova.FormatCompatibility.migratable, info.compatibility);
    }

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "migrate-verify-dest.zova");

    var json = try runCli(&.{ "zova", "migrate", "--json", source_path, dest_path });
    defer json.deinit();
    try std.testing.expectEqual(@as(u8, 4), json.code);
    var parsed = try parseJson(json.stderr);
    defer parsed.deinit();
    try expectJsonString(parsed.value.object, "command", "migrate");
    try expectJsonString(parsed.value.object, "status", "error");
    // kind is "verification failed" for verification errors
    const kind_val = parsed.value.object.get("kind") orelse return error.MissingJsonField;
    try std.testing.expect(std.mem.indexOf(u8, kind_val.string, "verification") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.stderr, "_zova_") == null);
    try std.testing.expect(std.mem.indexOf(u8, json.stderr, "select") == null);
    try expectPathMissing(dest_path);
    // source preserved
    const after_hash = try fileSha256(source_path);
    // hash should differ from before due to corruption, but not further changed by failed migrate
    // re-hash after migrate should equal hash after corruption (i.e., stable)
    const corrupted_hash = after_hash;
    var second_json = try runCli(&.{ "zova", "migrate", "--json", source_path, dest_path });
    defer second_json.deinit();
    try std.testing.expectEqual(@as(u8, 4), second_json.code);
    const after_second_hash = try fileSha256(source_path);
    try std.testing.expectEqualSlices(u8, &corrupted_hash, &after_second_hash);
    try expectPathMissing(dest_path);

    // --no-verify would still publish (but we don't test that it bypasses verification here to avoid masking)
    _ = before_hash;
}

fn copyFixtureFile(fixture_path: []const u8, dest_path: [:0]const u8) !void {
    const io = defaultIo();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, fixture_path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest_path, .data = bytes });
}

fn fileSha256(path: [:0]const u8) ![32]u8 {
    const io = defaultIo();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn createSyntheticFormatDatabase(path: [:0]const u8, version_text: []const u8) !void {
    try createHealthyDatabase(path);
    var raw = try zova.sqlite.Database.open(path);
    defer raw.deinit();
    var stmt = try raw.prepare("update _zova_meta set value = ? where key = 'format_version'");
    defer stmt.deinit();
    try stmt.bindText(1, version_text);
    _ = try stmt.step();
}

fn setupMigrateBoundSet(
    tmp: *std.testing.TmpDir,
    set_dir: []const u8,
    main_path: [:0]const u8,
    objects_path: [:0]const u8,
    vectors_path: [:0]const u8,
    graphs_path: [:0]const u8,
) !void {
    const io = defaultIo();
    try std.Io.Dir.cwd().createDirPath(io, set_dir);
    try copyFixtureFile("tests/fixtures/bound-main-format-9.zova", main_path);
    try copyFixtureFile("tests/fixtures/bound-main-format-9.objects.zova", objects_path);
    try copyFixtureFile("tests/fixtures/bound-main-format-9.vectors.zova", vectors_path);
    try copyFixtureFile("tests/fixtures/bound-main-format-9.graphs.zova", graphs_path);
    var raw = try zova.sqlite.Database.open(main_path);
    defer raw.deinit();
    const updates = [_]struct { role: []const u8, path: [:0]const u8 }{
        .{ .role = "object_store", .path = objects_path },
        .{ .role = "vector_store", .path = vectors_path },
        .{ .role = "graph_store", .path = graphs_path },
    };
    for (updates) |entry| {
        var stmt = try raw.prepare("update _zova_bound_stores set path = ?1 where role = ?2");
        defer stmt.deinit();
        try stmt.bindText(1, entry.path);
        try stmt.bindText(2, entry.role);
        _ = try stmt.step();
        try stmt.reset();
    }
    _ = tmp;
}

fn createHealthyDatabase(path: [:0]const u8) !void {
    var db = try zova.Database.create(path);
    defer db.deinit();

    try db.exec(
        \\create table documents (
        \\  id integer primary key,
        \\  object_id blob not null,
        \\  vector_id text not null,
        \\  title text not null
        \\)
    );

    const id = try db.putObject("hello object");
    try insertDocument(&db, id, "doc-1", "hello.txt");
    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("docs", "doc-1", .{ .f32 = &.{ 7.25, 8.5 } });
    try db.putObjectChunk(zova.objectChunkId("hidden chunk bytes"), "hidden chunk bytes");

    var writer = try db.objectWriter(std.testing.allocator);
    defer writer.deinit();
    try writer.write("streamed ");
    try writer.write("object");
    _ = try writer.finish();
}

fn createCorruptObjectDatabase(path: [:0]const u8) !void {
    {
        var db = try zova.Database.create(path);
        defer db.deinit();
        _ = try db.putObject("corrupt me");
    }

    var raw = try zova.sqlite.Database.open(path);
    defer raw.deinit();
    try raw.exec("update _zova_chunks set data = zeroblob(size_bytes) where chunk_hash = (select chunk_hash from _zova_chunks limit 1)");
}

fn addRichUserSqlFixture(path: [:0]const u8) !void {
    var db = try zova.Database.open(path);
    defer db.deinit();

    try db.exec(
        \\create table attachments (
        \\  id integer primary key,
        \\  label text not null,
        \\  payload blob not null
        \\);
        \\create table attachment_audit (
        \\  attachment_id integer not null,
        \\  label text not null
        \\);
        \\create index attachments_label_idx on attachments(label);
        \\create view attachment_labels as
        \\  select id, label from attachments;
        \\create trigger attachments_ai after insert on attachments
        \\begin
        \\  insert into attachment_audit (attachment_id, label) values (new.id, new.label);
        \\end;
    );

    var insert = try db.prepare("insert into attachments (label, payload) values (?, ?)");
    defer insert.deinit();
    try insert.bindText(1, "invoice");
    try insert.bindBlob(2, "secret blob value");
    try std.testing.expectEqual(zova.sqlite.Step.done, try insert.step());
}

fn expectRichUserSqlFixture(path: [:0]const u8) !void {
    var db = try zova.Database.open(path);
    defer db.deinit();

    try std.testing.expectEqual(@as(i64, 1), try countRows(&db, "select count(*) from attachments"));
    try std.testing.expectEqual(@as(i64, 1), try countRows(&db, "select count(*) from attachment_audit"));
    try std.testing.expectEqual(@as(i64, 1), try countRows(&db, "select count(*) from attachment_labels where label = 'invoice'"));

    var payload = try db.prepare("select payload from attachments where label = 'invoice'");
    defer payload.deinit();
    try std.testing.expectEqual(zova.sqlite.Step.row, try payload.step());
    try std.testing.expectEqualStrings("secret blob value", payload.columnBlob(0));

    try db.exec("insert into attachments (label, payload) values ('receipt', x'010203')");
    try std.testing.expectEqual(@as(i64, 2), try countRows(&db, "select count(*) from attachment_audit"));
}

fn expectHealthyCopy(path: [:0]const u8) !void {
    var db = try zova.Database.open(path);
    defer db.deinit();

    try std.testing.expectEqual(@as(i64, 1), try countRows(&db, "select count(*) from documents"));

    var object_row = try db.prepare("select object_id from documents order by id limit 1");
    defer object_row.deinit();
    try std.testing.expectEqual(zova.sqlite.Step.row, try object_row.step());
    const object_blob = object_row.columnBlob(0);
    try std.testing.expectEqual(@as(usize, 32), object_blob.len);
    var object_id: zova.ObjectId = undefined;
    @memcpy(object_id[0..], object_blob);

    var object = try db.getObject(std.testing.allocator, object_id);
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello object", object.bytes);

    var results = try db.searchVectors(std.testing.allocator, "docs", .{ .f32 = &.{ 7.25, 8.5 } }, 1);
    defer results.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("doc-1", results.items[0].id);

    var loose = try db.getObjectChunk(std.testing.allocator, zova.objectChunkId("hidden chunk bytes"));
    defer loose.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hidden chunk bytes", loose.bytes);
}

fn insertDocument(db: *zova.Database, object_id: zova.ObjectId, vector_id: []const u8, title: []const u8) !void {
    var insert = try db.prepare("insert into documents (object_id, vector_id, title) values (?, ?, ?)");
    defer insert.deinit();
    try insert.bindBlob(1, &object_id);
    try insert.bindText(2, vector_id);
    try insert.bindText(3, title);
    try std.testing.expectEqual(zova.sqlite.Step.done, try insert.step());
}

fn countRows(db: *zova.Database, sql: [:0]const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    return stmt.columnInt64(0);
}

fn countRawRows(db: *zova.sqlite.Database, sql: [:0]const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    return stmt.columnInt64(0);
}

fn createUnavailableExtensionFixture(db_path: [:0]const u8) !void {
    {
        var db = try zova.Database.create(db_path);
        defer db.deinit();
    }
    var raw = try zova.sqlite.Database.open(db_path);
    defer raw.deinit();
    try raw.exec(
        \\insert into _zova_extensions
        \\  (name, version, storage_prefix, zova_abi_min, capabilities, required, installed_at_unix, manifest_json)
        \\values ('test', '0.1.0', '_zova_ext_test_', '0.21.0', 'sql', 1, 0, '')
    );
    try raw.exec("create table _zova_ext_test_meta (key text primary key, value text not null)");
}

fn testingDbPath(buffer: []u8, sub_path: []const u8, name: []const u8) ![:0]u8 {
    return try std.fmt.bufPrintZ(buffer, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn setTestEnv(name: []const u8, value: []const u8) !void {
    const allocator = std.testing.allocator;
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    const value_z = try allocator.dupeZ(u8, value);
    defer allocator.free(value_z);
    if (setenv(name_z.ptr, value_z.ptr, 1) != 0) return error.SetEnvFailed;
}

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectFileExists(dir: std.Io.Dir, sub_path: []const u8) !void {
    const io = defaultIo();
    var file = try dir.openFile(io, sub_path, .{});
    file.close(io);
}

fn expectPathMissing(path: []const u8) !void {
    const io = defaultIo();
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    file.close(io);
    return error.UnexpectedFile;
}

fn expectArtifactHasSymbol(path: []const u8, symbol: []const u8) !void {
    try expectArtifactNonEmpty(path);

    var result = try runSymbolTool(path);
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, symbol) != null or
        std.mem.indexOf(u8, result.stderr, symbol) != null);
}

fn expectArtifactNonEmpty(path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, std.testing.allocator, .limited(256 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len > 0);
}

fn runSymbolTool(path: []const u8) !ProcessResult {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const argv = [_][]const u8{ "nm", path };
    return runProcessForTest(&argv, null, null);
}

fn runZigBridgeArtifactCommand(
    comptime mode: []const u8,
    source_path: []const u8,
    output_path: []const u8,
    cache_path: []const u8,
    global_cache_path: []const u8,
) !ProcessResult {
    const allocator = std.testing.allocator;
    const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{output_path});
    defer allocator.free(emit_arg);
    const root_arg = try std.fmt.allocPrint(allocator, "-Mroot={s}", .{source_path});
    defer allocator.free(root_arg);
    const zova_root_path = try std.fs.path.join(allocator, &.{ cli.source_root, "src/root.zig" });
    defer allocator.free(zova_root_path);
    const zova_arg = try std.fmt.allocPrint(allocator, "-Mzova={s}", .{zova_root_path});
    defer allocator.free(zova_arg);
    const sqlite_vendor_dir = try std.fmt.allocPrint(allocator, "sqlite{s}", .{zova.version.sqlite_version});
    defer allocator.free(sqlite_vendor_dir);
    const sqlite_include_path = try std.fs.path.join(allocator, &.{ cli.source_root, "vendor", sqlite_vendor_dir });
    defer allocator.free(sqlite_include_path);
    const zova_build_options_path = try std.fs.path.join(allocator, &.{ cache_path, "zova_build_options.zig" });
    defer allocator.free(zova_build_options_path);
    try std.Io.Dir.cwd().createDirPath(defaultIo(), cache_path);
    try std.Io.Dir.cwd().writeFile(defaultIo(), .{
        .sub_path = zova_build_options_path,
        .data = "pub const enable_dynamic_extensions = true;\n",
    });
    const zova_build_options_arg = try std.fmt.allocPrint(allocator, "-Mzova_build_options={s}", .{zova_build_options_path});
    defer allocator.free(zova_build_options_arg);

    const command = comptime if (std.mem.eql(u8, mode, "build-obj"))
        "build-obj"
    else if (std.mem.eql(u8, mode, "build-lib-static"))
        "build-lib"
    else
        @compileError("unsupported bridge artifact command");

    if (comptime std.mem.eql(u8, mode, "build-lib-static")) {
        const argv = [_][]const u8{
            cli.zig_exe,
            command,
            "-static",
            "-fPIC",
            "-lc",
            emit_arg,
            "--cache-dir",
            cache_path,
            "--global-cache-dir",
            global_cache_path,
            "--name",
            "bridge_artifact_extension",
            "--dep",
            "zova",
            root_arg,
            "-I",
            sqlite_include_path,
            "--dep",
            "zova_build_options",
            zova_arg,
            zova_build_options_arg,
        };
        return runProcessForTest(&argv, cache_path, global_cache_path);
    }

    const argv = [_][]const u8{
        cli.zig_exe,
        command,
        "-fPIC",
        "-lc",
        emit_arg,
        "--cache-dir",
        cache_path,
        "--global-cache-dir",
        global_cache_path,
        "--name",
        "bridge_artifact_extension",
        "--dep",
        "zova",
        root_arg,
        "-I",
        sqlite_include_path,
        "--dep",
        "zova_build_options",
        zova_arg,
        zova_build_options_arg,
    };
    return runProcessForTest(&argv, cache_path, global_cache_path);
}

fn runProcessForTest(argv: []const []const u8, cache_path: ?[]const u8, global_cache_path: ?[]const u8) !ProcessResult {
    return runProcessForTestInCwd(argv, cache_path, global_cache_path, null);
}

fn runProcessForTestInCwd(argv: []const []const u8, cache_path: ?[]const u8, global_cache_path: ?[]const u8, cwd: ?[]const u8) !ProcessResult {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try copyTestEnv(&env, "PATH");
    if (env.get("PATH") == null) try env.put("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin");
    try copyTestEnv(&env, "HOME");
    try copyTestEnv(&env, "TMPDIR");
    try copyTestEnv(&env, "TMP");
    try copyTestEnv(&env, "TEMP");
    try copyTestEnv(&env, "DYLD_LIBRARY_PATH");
    try copyTestEnv(&env, "LD_LIBRARY_PATH");
    try copyTestEnv(&env, "ZIG_GLOBAL_CACHE_DIR");
    if (global_cache_path) |path| {
        try env.put("ZIG_GLOBAL_CACHE_DIR", path);
        try env.put("HOME", path);
    }
    if (cache_path) |path| try env.put("TMPDIR", path);

    const child_cwd: std.process.Child.Cwd = if (cwd) |path| .{ .path = path } else .inherit;
    const result = try std.process.run(std.testing.allocator, threaded.io(), .{
        .argv = argv,
        .cwd = child_cwd,
        .environ_map = &env,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    return .{
        .code = switch (result.term) {
            .exited => |value| @intCast(@min(value, 255)),
            else => 255,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn copyTestEnv(env: *std.process.Environ.Map, name: [:0]const u8) !void {
    const value = std.c.getenv(name.ptr) orelse return;
    try env.put(name, std.mem.span(value));
}

fn absolutePathAlloc(path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return try std.testing.allocator.dupe(u8, path);
    const cwd = try std.process.currentPathAlloc(defaultIo(), std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    return try std.fs.path.join(std.testing.allocator, &.{ cwd, path });
}

fn missingHexId() []const u8 {
    return "0000000000000000000000000000000000000000000000000000000000000000";
}

fn queryText(path: [:0]const u8, sql: [:0]const u8) ![]u8 {
    var db = try zova.sqlite.Database.open(path);
    defer db.deinit();

    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    return switch (try stmt.step()) {
        .row => try std.testing.allocator.dupe(u8, stmt.columnText(0)),
        .done => error.NoRows,
    };
}

fn asciiUpperAlloc(value: []const u8) ![]u8 {
    const out = try std.testing.allocator.dupe(u8, value);
    for (out) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return out;
}

fn lowerHexAlloc(bytes: []const u8) ![]u8 {
    const digits = "0123456789abcdef";
    const out = try std.testing.allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        out[index * 2] = digits[@intCast(byte >> 4)];
        out[index * 2 + 1] = digits[@intCast(byte & 0x0f)];
    }
    return out;
}

fn fillDeterministic(bytes: []u8) void {
    for (bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 31 + index / 7 + 11) % 256);
    }
}

fn markerExtensionSource(marker_path: []const u8) ![]u8 {
    return markerExtensionSourceFor("smoke_marker_ext", marker_path);
}

fn markerExtensionSourceFor(extension_name: []const u8, marker_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator,
        \\const std = @import("std");
        \\const zova = @import("zova");
        \\
        \\const HookError = error{{ ExtensionInvalid }};
        \\
        \\const manifest = zova.ExtensionManifest{{
        \\    .name = "{s}",
        \\    .version = "0.1.0",
        \\    .storage_prefix = "_zova_ext_{s}_",
        \\    .zova_abi_min = "{s}",
        \\    .capabilities = "experimental-builder",
        \\    .required = true,
        \\}};
        \\
        \\const extension = zova.Extension{{
        \\    .manifest = manifest,
        \\    .install = install,
        \\    .check = check,
        \\    .drop = drop,
        \\}};
        \\
        \\pub export fn zova_extension_entry() callconv(.c) *const zova.Extension {{
        \\    return &extension;
        \\}}
        \\
        \\fn install(_: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {{
        \\    const file = std.c.fopen("{s}", "wb") orelse return error.ExtensionInvalid;
        \\    defer _ = std.c.fclose(file);
        \\    if (std.c.fwrite("installed", 1, "installed".len, file) != "installed".len) return error.ExtensionInvalid;
        \\}}
        \\
        \\fn check(_: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {{
        \\    if (std.c.access("{s}", std.c.F_OK) != 0) return error.ExtensionInvalid;
        \\}}
        \\
        \\fn drop(_: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {{
        \\}}
        \\
    , .{ extension_name, extension_name, cli.package_version, marker_path, marker_path });
}

fn testBuilderManifest(
    name: []const u8,
    version: []const u8,
    storage_prefix: []const u8,
    capabilities: []const u8,
    library: []const u8,
    entrypoint: ?[]const u8,
) ![]u8 {
    if (entrypoint) |value| {
        return std.fmt.allocPrint(std.testing.allocator,
            \\{{
            \\  "name": "{s}",
            \\  "version": "{s}",
            \\  "storage_prefix": "{s}",
            \\  "zova_abi_min": "{s}",
            \\  "capabilities": "{s}",
            \\  "library": "{s}",
            \\  "entrypoint": "{s}"
            \\}}
            \\
        , .{ name, version, storage_prefix, cli.package_version, capabilities, library, value });
    }

    return std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  "name": "{s}",
        \\  "version": "{s}",
        \\  "storage_prefix": "{s}",
        \\  "zova_abi_min": "{s}",
        \\  "capabilities": "{s}",
        \\  "library": "{s}"
        \\}}
        \\
    , .{ name, version, storage_prefix, cli.package_version, capabilities, library });
}

fn testDynamicLibraryFileName(name: []const u8) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => try std.fmt.allocPrint(std.testing.allocator, "{s}.dll", .{name}),
        .macos, .ios, .tvos, .watchos, .visionos => try std.fmt.allocPrint(std.testing.allocator, "lib{s}.dylib", .{name}),
        else => try std.fmt.allocPrint(std.testing.allocator, "lib{s}.so", .{name}),
    };
}

fn simpleArtifactExtensionSource() []const u8 {
    return
    \\const zova = @import("zova");
    \\
    \\const HookError = error{ ExtensionInvalid };
    \\
    \\const manifest = zova.ExtensionManifest{
    \\    .name = "bridge_artifact",
    \\    .version = "0.1.0",
    \\    .storage_prefix = "_zova_ext_bridge_artifact_",
    \\    .zova_abi_min = "0.26.1",
    \\    .capabilities = "artifact-test",
    \\    .required = true,
    \\};
    \\
    \\const extension = zova.Extension{
    \\    .manifest = manifest,
    \\    .install = install,
    \\    .check = check,
    \\    .drop = drop,
    \\};
    \\
    \\pub export fn zova_extension_entry() callconv(.c) *const zova.Extension {
    \\    return &extension;
    \\}
    \\
    \\fn install(_: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {
    \\}
    \\
    \\fn check(_: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {
    \\}
    \\
    \\fn drop(_: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {
    \\}
    \\
    ;
}

fn failingCheckExtensionSource() []const u8 {
    return
    \\const zova = @import("zova");
    \\
    \\const HookError = error{ ExtensionInvalid };
    \\
    \\const manifest = zova.ExtensionManifest{
    \\    .name = "smoke_bad_ext",
    \\    .version = "0.1.0",
    \\    .storage_prefix = "_zova_ext_smoke_bad_ext_",
    \\    .zova_abi_min = "0.26.1",
    \\    .capabilities = "experimental-builder",
    \\    .required = true,
    \\};
    \\
    \\const extension = zova.Extension{
    \\    .manifest = manifest,
    \\    .install = install,
    \\    .check = check,
    \\    .drop = drop,
    \\};
    \\
    \\pub export fn zova_extension_entry() callconv(.c) *const zova.Extension {
    \\    return &extension;
    \\}
    \\
    \\fn install(_: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {
    \\}
    \\
    \\fn check(_: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {
    \\    return error.ExtensionInvalid;
    \\}
    \\
    \\fn drop(_: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {
    \\}
    \\
    ;
}

fn parseJson(bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
}

fn expectJsonInt(object: std.json.ObjectMap, key: []const u8, expected: i64) !void {
    const value = object.get(key) orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.integer, std.meta.activeTag(value));
    try std.testing.expectEqual(expected, value.integer);
}

fn expectJsonString(object: std.json.ObjectMap, key: []const u8, expected: []const u8) !void {
    const value = object.get(key) orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.string, std.meta.activeTag(value));
    try std.testing.expectEqualStrings(expected, value.string);
}

fn expectJsonObjectHasInt(object: std.json.ObjectMap, object_key: []const u8, key: []const u8) !void {
    _ = try jsonObjectInt(object, object_key, key);
}

fn jsonObjectInt(object: std.json.ObjectMap, object_key: []const u8, key: []const u8) !i64 {
    const value = object.get(object_key) orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.object, std.meta.activeTag(value));
    const child = value.object.get(key) orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.integer, std.meta.activeTag(child));
    return child.integer;
}

fn expectJsonArray(object: std.json.ObjectMap, key: []const u8) !void {
    const value = object.get(key) orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.array, std.meta.activeTag(value));
}

fn expectJsonArrayLen(object: std.json.ObjectMap, key: []const u8, expected: usize) !void {
    const value = object.get(key) orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.array, std.meta.activeTag(value));
    try std.testing.expectEqual(expected, value.array.items.len);
}

fn expectJsonBool(object: std.json.ObjectMap, key: []const u8, expected: bool) !void {
    const value = object.get(key) orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.bool, std.meta.activeTag(value));
    try std.testing.expectEqual(expected, value.bool);
}
