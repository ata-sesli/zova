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
