const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sqlite_dir = b.path("../../vendor/sqlite3.53.4");

    const c_headers = b.addTranslateC(.{
        .root_source_file = b.path("src/csys.h"),
        .target = target,
        .optimize = optimize,
    });
    c_headers.addIncludePath(sqlite_dir);

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("c", c_headers.createModule());
    // The bundled SQLite, unmodified, with Zova's production threading flag.
    // SQLITE_ENABLE_SNAPSHOT is not in Zova's build; snapshot reads need it.
    // SQLITE_MAX_ATTACHED=31 lets a set reach 32 files.
    module.addCSourceFile(.{
        .file = b.path("../../vendor/sqlite3.53.4/sqlite3.c"),
        .flags = &.{ "-std=c99", "-fno-sanitize=undefined", "-DSQLITE_THREADSAFE=1", "-DSQLITE_ENABLE_SNAPSHOT", "-DSQLITE_MAX_ATTACHED=31" },
    });
    const exe = b.addExecutable(.{ .name = "cwal", .root_module = module });
    b.installArtifact(exe);
}
