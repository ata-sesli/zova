const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const package_version = packageVersion(b);

    const zova_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSqlite(zova_module, b);

    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_module.addImport("zova", zova_module);
    const cli_options = b.addOptions();
    cli_options.addOption([]const u8, "package_version", package_version);
    cli_module.addOptions("cli_options", cli_options);

    const exe = b.addExecutable(.{
        .name = "zova",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("cli", cli_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addArg("--version");

    const run_step = b.step("run", "Run Zova");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addSqlite(tests.root_module, b);

    const test_cmd = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_cmd.step);

    const c_api_tests = b.addTest(.{
        .name = "c-api-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addSqlite(c_api_tests.root_module, b);
    const c_api_test_cmd = b.addRunArtifact(c_api_tests);
    test_step.dependOn(&c_api_test_cmd.step);

    const e2e_module = b.createModule(.{
        .root_source_file = b.path("tests/e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_module.addImport("zova", zova_module);

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
    const cli_tests_cmd = b.addRunArtifact(cli_tests);
    const cli_test_step = b.step("cli-test", "Run CLI tests");
    cli_test_step.dependOn(&cli_tests_cmd.step);
    test_step.dependOn(&cli_tests_cmd.step);

    const c_abi_lib = b.addLibrary(.{
        .name = "zova_c",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addSqlite(c_abi_lib.root_module, b);

    const c_abi_step = b.step("c-abi", "Build the Zova C ABI static library");
    c_abi_step.dependOn(&c_abi_lib.step);

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
    c_smoke_module.linkLibrary(c_abi_lib);

    const c_smoke = b.addExecutable(.{
        .name = "zova_c_abi_smoke",
        .root_module = c_smoke_module,
    });
    const c_abi_smoke_db_path = b.pathJoin(&.{ b.cache_root.path orelse ".zig-cache", "c-abi-smoke.zova" });
    const c_smoke_cmd = b.addRunArtifact(c_smoke);
    c_smoke_cmd.addArg(c_abi_smoke_db_path);

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

fn addSqlite(module: *std.Build.Module, b: *std.Build) void {
    module.addIncludePath(b.path("vendor/sqlite3.53.2"));
    module.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.53.2/sqlite3.c"),
        .flags = &.{
            "-std=c99",
            // Keep SQLite's mutex support enabled for normal embedded use.
            "-DSQLITE_THREADSAFE=1",
            // Promise FTS5 as part of Zova's vendored SQLite build, without
            // adding a Zova-specific search API.
            "-DSQLITE_ENABLE_FTS5",
        },
    });
    module.link_libc = true;
}

fn packageVersion(b: *std.Build) []const u8 {
    const manifest = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "build.zig.zon",
        b.allocator,
        .limited(64 * 1024),
    ) catch @panic("unable to read build.zig.zon");
    const marker = ".version = \"";
    const start = std.mem.indexOf(u8, manifest, marker) orelse @panic("build.zig.zon is missing .version");
    const value_start = start + marker.len;
    const value_end = std.mem.indexOfScalarPos(u8, manifest, value_start, '"') orelse @panic("build.zig.zon has malformed .version");
    return manifest[value_start..value_end];
}
