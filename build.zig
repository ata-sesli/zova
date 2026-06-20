const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zova",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addSqlite(exe.root_module, b);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

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

    const zova_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSqlite(zova_module, b);

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
    const c_smoke_cmd = b.addRunArtifact(c_smoke);
    c_smoke_cmd.addArg(b.pathJoin(&.{ b.cache_root.path orelse ".zig-cache", "c-abi-smoke.zova" }));

    const c_abi_test_step = b.step("c-abi-test", "Run the C ABI smoke test");
    c_abi_test_step.dependOn(&c_smoke_cmd.step);
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
