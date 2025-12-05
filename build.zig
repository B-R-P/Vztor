const std = @import("std");

pub fn build(b: *std.Build) void {
    // ------------------------------------------------------------
    // Build options (standard)
    // ------------------------------------------------------------
    const target = b.standardTargetOptions(.{});

    // ------------------------------------------------------------
    // Dependencies
    // ------------------------------------------------------------
    const nmslib_dep = b.dependency("nmslib", .{});
    const lmdbx_dep  = b.dependency("lmdbx",  .{
        .optimize = .Debug,
    });

    // ------------------------------------------------------------
    // Optional build-time flags
    // ------------------------------------------------------------
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "strip", false);
    build_opts.addOption(bool, "lto", false);

    // ------------------------------------------------------------
    // Executable (fast debug build)
    // ------------------------------------------------------------
    const exe_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
    });

    const exe = b.addExecutable(.{
        .name = "VStore",
        .root_module = exe_root,
    });

    exe.root_module.addImport("build_opts", build_opts.createModule());
    exe.root_module.addImport("utils", b.createModule(.{
        .root_source_file = b.path("src/utils.zig"),
    }));

    exe.root_module.addImport("lmdbx", lmdbx_dep.module("lmdbx"));
    exe.root_module.addImport("nmslib", nmslib_dep.module("nmslib"));

    exe.linkLibCpp();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run VStore in debug mode");
    run_step.dependOn(&run_cmd.step);

    // ------------------------------------------------------------
    // Tests (test blocks are in src/main.zig)
    // ------------------------------------------------------------
    const test_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug, // good for assertions & debug info
    });

    const tests = b.addTest(.{
        .root_module = test_root,
    });

    // mirror imports so tests see same world as exe
    tests.root_module.addImport("build_opts", build_opts.createModule());
    tests.root_module.addImport("utils", b.createModule(.{
        .root_source_file = b.path("src/utils.zig"),
    }));
    tests.root_module.addImport("lmdbx", lmdbx_dep.module("lmdbx"));
    tests.root_module.addImport("nmslib", nmslib_dep.module("nmslib"));

    tests.linkLibCpp();

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run VStore tests");
    test_step.dependOn(&run_tests.step);
}
