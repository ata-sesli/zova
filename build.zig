const std = @import("std");

const sqlite_c_flags = &.{
    "-std=c99",
    // Keep the static C ABI library consumable by external linkers such as
    // cgo without requiring Zig/Clang sanitizer runtimes.
    "-fno-sanitize=undefined",
    // Keep SQLite's mutex support enabled for normal embedded use.
    "-DSQLITE_THREADSAFE=1",
    // Promise FTS5 as part of Zova's vendored SQLite build, without adding a
    // Zova-specific search API.
    "-DSQLITE_ENABLE_FTS5",
    "-DSQLITE_ENABLE_DBSTAT_VTAB",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const package_version = packageVersion(b);
    const enable_dynamic_extensions = b.option(bool, "enable-dynamic-extensions", "Enable dynamic .zovaext loading") orelse true;
    const supports_dynamic_extension_fixture = enable_dynamic_extensions and target.result.os.tag != .windows;

    const zova_build_options = b.addOptions();
    zova_build_options.addOption(bool, "enable_dynamic_extensions", enable_dynamic_extensions);

    const sqlite_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sqlite_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.53.2/sqlite3.c"),
        .flags = sqlite_c_flags,
    });
    const sqlite_lib = b.addLibrary(.{
        .name = "zova_sqlite",
        .linkage = .static,
        .root_module = sqlite_module,
    });

    const zova_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zova_module.addOptions("zova_build_options", zova_build_options);
    addSqlite(zova_module, b, sqlite_lib);

    const zova_dynamic_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zova_dynamic_module.addOptions("zova_build_options", zova_build_options);
    zova_dynamic_module.addIncludePath(b.path("vendor/sqlite3.53.2"));

    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_module.addImport("zova", zova_module);
    const cli_options = b.addOptions();
    const zova_exe_filename = std.zig.binNameAlloc(b.allocator, .{
        .root_name = "zova",
        .target = &target.result,
        .output_mode = .Exe,
    }) catch @panic("out of memory");
    const zova_exe_path = b.getInstallPath(.bin, zova_exe_filename);
    cli_options.addOption([]const u8, "package_version", package_version);
    cli_options.addOptionPath("source_root", b.path("."));
    cli_options.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    cli_options.addOption([]const u8, "zova_exe_path", zova_exe_path);
    cli_module.addOptions("cli_options", cli_options);

    var dynamic_extension_fixture: ?*std.Build.Step.Compile = null;
    if (supports_dynamic_extension_fixture) {
        const fixture = b.addLibrary(.{
            .name = "zova_dyn_test",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/dynamic_extension_fixture.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        fixture.root_module.addImport("zova", zova_dynamic_module);
        fixture.linker_allow_shlib_undefined = true;
        fixture.root_module.link_libc = true;
        dynamic_extension_fixture = fixture;
        cli_options.addOptionPath("dynamic_extension_library_path", fixture.getEmittedBin());
    } else {
        cli_options.addOption([]const u8, "dynamic_extension_library_path", "");
    }

    const exe = b.addExecutable(.{
        .name = "zova",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("cli", cli_module);
    exe.rdynamic = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addArg("--version");

    const run_step = b.step("run", "Run Zova");
    run_step.dependOn(&run_cmd.step);

    const storage_benchmark = b.addExecutable(.{
        .name = "zova_storage_benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/storage_format.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    storage_benchmark.root_module.addImport("zova", zova_module);
    const storage_benchmark_cmd = b.addRunArtifact(storage_benchmark);
    storage_benchmark_cmd.addArg(b.pathJoin(&.{ b.cache_root.path orelse ".zig-cache", "storage-format-benchmark.zova" }));
    if (b.args) |args| storage_benchmark_cmd.addArgs(args);
    const storage_benchmark_step = b.step("bench-storage", "Run deterministic graph/vector storage benchmark");
    storage_benchmark_step.dependOn(&storage_benchmark_cmd.step);

    const object_benchmark = b.addExecutable(.{
        .name = "zova_object_storage_benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/object_storage.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    object_benchmark.root_module.addImport("object_impl", b.createModule(.{
        .root_source_file = b.path("src/object.zig"),
        .target = target,
        .optimize = optimize,
    }));
    object_benchmark.root_module.addImport("version_impl", b.createModule(.{
        .root_source_file = b.path("src/version.zig"),
        .target = target,
        .optimize = optimize,
    }));
    object_benchmark.root_module.addIncludePath(b.path("vendor/sqlite3.53.2"));
    object_benchmark.root_module.linkLibrary(sqlite_lib);
    const object_benchmark_cmd = b.addRunArtifact(object_benchmark);
    if (b.args) |args| object_benchmark_cmd.addArgs(args);
    const object_benchmark_step = b.step("bench-objects", "Run FastCDC object storage benchmark");
    object_benchmark_step.dependOn(&object_benchmark_cmd.step);

    const graph_keyed_benchmark = b.addExecutable(.{
        .name = "zova_graph_keyed_benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/graph_keyed.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    graph_keyed_benchmark.root_module.addImport("zova", zova_module);
    const graph_keyed_benchmark_cmd = b.addRunArtifact(graph_keyed_benchmark);
    if (b.args) |args| graph_keyed_benchmark_cmd.addArgs(args);
    const graph_keyed_benchmark_step = b.step("bench-graph-keyed", "Compare current and opaque-key graph batches");
    graph_keyed_benchmark_step.dependOn(&graph_keyed_benchmark_cmd.step);

    const graph_fresh_benchmark = b.addExecutable(.{
        .name = "zova_graph_fresh_benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/graph_fresh.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    graph_fresh_benchmark.root_module.addImport("zova", zova_module);
    const graph_fresh_benchmark_cmd = b.addRunArtifact(graph_fresh_benchmark);
    if (b.args) |args| graph_fresh_benchmark_cmd.addArgs(args);
    const graph_fresh_benchmark_step = b.step("bench-graph-fresh", "Compare incremental and fresh graph publication at Deno scale");
    graph_fresh_benchmark_step.dependOn(&graph_fresh_benchmark_cmd.step);

    const notifications_benchmark = b.addExecutable(.{
        .name = "zova_notifications_benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/notifications.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    notifications_benchmark.root_module.addImport("zova", zova_module);
    const notifications_benchmark_cmd = b.addRunArtifact(notifications_benchmark);
    if (b.args) |args| notifications_benchmark_cmd.addArgs(args);
    const notifications_benchmark_step = b.step("bench-notifications", "Run deterministic transaction-aware notification throughput benchmark");
    notifications_benchmark_step.dependOn(&notifications_benchmark_cmd.step);

    const ablation_api_module = b.createModule(.{
        .root_source_file = b.path("src/c_api_internal.zig"),
        .target = target,
        .optimize = optimize,
    });
    ablation_api_module.addOptions("zova_build_options", zova_build_options);
    addSqlite(ablation_api_module, b, sqlite_lib);
    const fresh_ablation_benchmark = b.addExecutable(.{
        .name = "zova_fresh_build_ablation",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/fresh_build_ablation.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fresh_ablation_benchmark.root_module.addImport("zova_c", ablation_api_module);
    const fresh_ablation_cmd = b.addRunArtifact(fresh_ablation_benchmark);
    if (b.args) |args| fresh_ablation_cmd.addArgs(args);
    const fresh_ablation_step = b.step("bench-fresh-ablation", "Run cumulative graph, metadata, FTS, and vector fresh-build ablations");
    fresh_ablation_step.dependOn(&fresh_ablation_cmd.step);

    const storage_compat_check = b.addExecutable(.{
        .name = "zova_storage_compat_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/storage_compat_check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    storage_compat_check.root_module.addOptions("zova_build_options", zova_build_options);
    addSqlite(storage_compat_check.root_module, b, sqlite_lib);
    const storage_compat_check_cmd = b.addRunArtifact(storage_compat_check);
    const storage_compat_check_step = b.step("check-storage-compat", "Verify the storage compatibility policy against the retained fixtures");
    storage_compat_check_step.dependOn(&storage_compat_check_cmd.step);

    const test_step = b.step("test", "Run all tests");
    const core_test_step = addZigTestSuite(
        b,
        "test-core",
        "Run core database and public API tests",
        "src/root.zig",
        &.{},
        target,
        optimize,
        zova_build_options,
        sqlite_lib,
    );
    const object_test_step = addZigTestSuite(
        b,
        "test-objects",
        "Run object storage tests",
        "src/test_objects_root.zig",
        &.{ "object_tests", "object.test." },
        target,
        optimize,
        zova_build_options,
        sqlite_lib,
    );
    const vector_test_step = addZigTestSuite(
        b,
        "test-vectors",
        "Run vector storage and SQL tests",
        "src/test_vectors_root.zig",
        &.{ "vector_tests", "vector_sql_tests", "vector.test." },
        target,
        optimize,
        zova_build_options,
        sqlite_lib,
    );
    const graph_test_step = addZigTestSuite(
        b,
        "test-graphs",
        "Run graph storage and SQL tests",
        "src/test_graphs_root.zig",
        &.{ "graph_tests", "graph_sql_tests", "graph.test." },
        target,
        optimize,
        zova_build_options,
        sqlite_lib,
    );
    const kv_test_step = addZigTestSuite(
        b,
        "test-kv",
        "Run key-value storage tests",
        "src/test_kv_root.zig",
        &.{ "kv_tests", "kv.test." },
        target,
        optimize,
        zova_build_options,
        sqlite_lib,
    );
    const extension_test_step = addZigTestSuite(
        b,
        "test-extensions",
        "Run extension and trigram tests",
        "src/test_extensions_root.zig",
        &.{ "extension test suite", "extension_dynamic", "trgm_tests" },
        target,
        optimize,
        zova_build_options,
        sqlite_lib,
    );
    const migration_test_step = addZigTestSuite(
        b,
        "test-migration",
        "Run storage-format migration tests",
        "src/test_migration_root.zig",
        &.{ "migration_red_tests", "migration_tests", "migration_parity_tests" },
        target,
        optimize,
        zova_build_options,
        sqlite_lib,
    );
    const c_api_test_step = addZigTestSuite(
        b,
        "test-c-api",
        "Run Zig C API tests",
        "src/c_api.zig",
        &.{},
        target,
        optimize,
        zova_build_options,
        sqlite_lib,
    );

    inline for (.{
        core_test_step,
        object_test_step,
        vector_test_step,
        graph_test_step,
        kv_test_step,
        extension_test_step,
        migration_test_step,
        c_api_test_step,
    }) |suite_step| test_step.dependOn(suite_step);

    const e2e_module = b.createModule(.{
        .root_source_file = b.path("tests/e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_module.addImport("zova", zova_module);
    e2e_module.addImport("cli", cli_module);

    const e2e_tests = b.addTest(.{
        .root_module = e2e_module,
    });

    const e2e_cmd = b.addRunArtifact(e2e_tests);
    const e2e_step = b.step("e2e", "Run end-to-end tests");
    e2e_step.dependOn(&e2e_cmd.step);

    const cli_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_tests_module.addImport("zova", zova_module);
    cli_tests_module.addImport("cli", cli_module);

    const cli_tests = b.addTest(.{
        .root_module = cli_tests_module,
    });
    cli_tests.rdynamic = true;
    const cli_tests_cmd = b.addRunArtifact(cli_tests);
    cli_tests_cmd.step.dependOn(b.getInstallStep());
    const cli_test_step = b.step("cli-test", "Run CLI tests");
    cli_test_step.dependOn(&cli_tests_cmd.step);
    const test_cli_step = b.step("test-cli", "Run CLI tests");
    test_cli_step.dependOn(&cli_tests_cmd.step);
    test_step.dependOn(test_cli_step);

    const c_abi_lib = b.addLibrary(.{
        .name = "zova_c",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    c_abi_lib.root_module.addOptions("zova_build_options", zova_build_options);
    addEmbeddedSqlite(c_abi_lib.root_module, b);

    const install_c_abi_lib = b.addInstallArtifact(c_abi_lib, .{});

    const c_abi_step = b.step("c-abi", "Build the Zova C ABI static library");
    c_abi_step.dependOn(&install_c_abi_lib.step);

    const c_smoke_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_smoke_module.addIncludePath(b.path("include"));
    c_smoke_module.addCSourceFile(.{
        .file = b.path("tests/c_abi_smoke.c"),
        .flags = &.{"-std=c99"},
    });
    c_smoke_module.linkSystemLibrary("pthread", .{});
    c_smoke_module.linkLibrary(c_abi_lib);

    const c_notifications_benchmark_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_notifications_benchmark_module.addIncludePath(b.path("include"));
    c_notifications_benchmark_module.addCSourceFile(.{
        .file = b.path("bench/notifications_c.c"),
        .flags = &.{"-std=c99"},
    });
    c_notifications_benchmark_module.linkSystemLibrary("pthread", .{});
    c_notifications_benchmark_module.linkLibrary(c_abi_lib);
    const c_notifications_benchmark = b.addExecutable(.{
        .name = "zova_c_notifications_benchmark",
        .root_module = c_notifications_benchmark_module,
    });
    const c_notifications_benchmark_cmd = b.addRunArtifact(c_notifications_benchmark);
    if (b.args) |args| c_notifications_benchmark_cmd.addArgs(args);
    const c_notifications_benchmark_step = b.step("bench-notifications-c", "Run C ABI transaction-aware notification throughput benchmark");
    c_notifications_benchmark_step.dependOn(&c_notifications_benchmark_cmd.step);

    const c_smoke = b.addExecutable(.{
        .name = "zova_c_abi_smoke",
        .root_module = c_smoke_module,
    });
    if (supports_dynamic_extension_fixture) c_smoke.rdynamic = true;
    const c_abi_smoke_db_path = b.pathJoin(&.{ b.cache_root.path orelse ".zig-cache", "c-abi-smoke.zova" });
    const c_smoke_cmd = b.addRunArtifact(c_smoke);
    c_smoke_cmd.addArg(c_abi_smoke_db_path);
    if (dynamic_extension_fixture) |fixture| {
        const c_abi_bundle_path = b.pathJoin(&.{ b.cache_root.path orelse ".zig-cache", "c-abi-dyn-test.zovaext" });
        const c_abi_trust_path = b.pathJoin(&.{ b.cache_root.path orelse ".zig-cache", "c-abi-trusted-extensions.json" });
        c_smoke_cmd.addArtifactArg(fixture);
        c_smoke_cmd.addArg(c_abi_bundle_path);
        c_smoke_cmd.addArg(c_abi_trust_path);
    }

    const cli_info_c_abi_db_cmd = b.addRunArtifact(exe);
    cli_info_c_abi_db_cmd.step.dependOn(&c_smoke_cmd.step);
    cli_info_c_abi_db_cmd.addArg("info");
    cli_info_c_abi_db_cmd.addArg(c_abi_smoke_db_path);

    const cli_check_c_abi_db_cmd = b.addRunArtifact(exe);
    cli_check_c_abi_db_cmd.step.dependOn(&c_smoke_cmd.step);
    cli_check_c_abi_db_cmd.addArg("check");
    cli_check_c_abi_db_cmd.addArg("--deep");
    cli_check_c_abi_db_cmd.addArg(c_abi_smoke_db_path);

    const cxx_header_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    cxx_header_module.addIncludePath(b.path("include"));
    cxx_header_module.addCSourceFile(.{
        .file = b.path("tests/c_abi_header_smoke.cpp"),
        .flags = &.{"-std=c++17"},
    });
    cxx_header_module.linkLibrary(c_abi_lib);

    const cxx_header_smoke = b.addExecutable(.{
        .name = "zova_c_abi_header_smoke",
        .root_module = cxx_header_module,
    });
    const cxx_header_cmd = b.addRunArtifact(cxx_header_smoke);

    const c_abi_symbols_cmd = b.addSystemCommand(&.{
        "sh",
        "tests/check_c_abi_symbols.sh",
    });
    c_abi_symbols_cmd.addArtifactArg(c_abi_lib);

    const c_abi_test_step = b.step("c-abi-test", "Run the C ABI smoke test");
    c_abi_test_step.dependOn(&c_smoke_cmd.step);
    c_abi_test_step.dependOn(&cli_info_c_abi_db_cmd.step);
    c_abi_test_step.dependOn(&cli_check_c_abi_db_cmd.step);
    c_abi_test_step.dependOn(&cxx_header_cmd.step);
    c_abi_test_step.dependOn(&c_abi_symbols_cmd.step);
}

fn addZigTestSuite(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    root_source: []const u8,
    filters: []const []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zova_build_options: *std.Build.Step.Options,
    sqlite_lib: *std.Build.Step.Compile,
) *std.Build.Step {
    const suite_step = b.step(name, description);
    const root_module = b.createModule(.{
        .root_source_file = b.path(root_source),
        .target = target,
        .optimize = optimize,
    });
    root_module.addOptions("zova_build_options", zova_build_options);
    addSqlite(root_module, b, sqlite_lib);
    const tests = b.addTest(.{
        .name = name,
        .root_module = root_module,
        .filters = filters,
    });
    const test_cmd = b.addRunArtifact(tests);
    suite_step.dependOn(&test_cmd.step);
    return suite_step;
}

fn addSqlite(
    module: *std.Build.Module,
    b: *std.Build,
    sqlite_lib: *std.Build.Step.Compile,
) void {
    module.addIncludePath(b.path("vendor/sqlite3.53.2"));
    module.linkLibrary(sqlite_lib);
}

fn addEmbeddedSqlite(module: *std.Build.Module, b: *std.Build) void {
    module.addIncludePath(b.path("vendor/sqlite3.53.2"));
    module.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.53.2/sqlite3.c"),
        .flags = sqlite_c_flags,
    });
    module.link_libc = true;
}

fn packageVersion(b: *std.Build) []const u8 {
    const version_source = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "src/version.zig",
        b.allocator,
        .limited(64 * 1024),
    ) catch @panic("unable to read src/version.zig");
    const marker = "pub const package_version = \"";
    const start = std.mem.indexOf(u8, version_source, marker) orelse @panic("src/version.zig is missing package_version");
    const value_start = start + marker.len;
    const value_end = std.mem.indexOfScalarPos(u8, version_source, value_start, '"') orelse @panic("src/version.zig has malformed package_version");
    return version_source[value_start..value_end];
}
