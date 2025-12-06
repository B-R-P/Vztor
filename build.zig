const std = @import("std");

pub fn build(b: *std.Build) void {
    // ------------------------------------------------------------
    // Build options (standard)
    // ------------------------------------------------------------
    const target = b.standardTargetOptions(.{});

    // ------------------------------------------------------------
    // Dependencies
    // ------------------------------------------------------------
    const nmslib_dep = b.dependency("nmslib", .{
    });
    const lmdbx_dep  = b.dependency("lmdbx",  .{
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
    const lib_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
    });

    // const nmslib_lib = nmslib_dep.artifact("nmslib");
    const nmslib_mod = nmslib_dep.module("nmslib");

    const lib = b.addLibrary(.{
        .name = "Vztor",
        .linkage = .static,
        .root_module = lib_root,
    });

    lib.root_module.addImport("build_opts", build_opts.createModule());
    lib.root_module.addImport("utils", b.createModule(.{
        .root_source_file = b.path("src/utils.zig"),
    }));

    lib.root_module.addImport("lmdbx", lmdbx_dep.module("lmdbx"));
    lib.root_module.addImport("nmslib", nmslib_mod);


    b.installArtifact(lib);

    const run_cmd = b.addRunArtifact(lib);
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

    // mirror imports so tests see same world as lib
    tests.root_module.addImport("build_opts", build_opts.createModule());
    tests.root_module.addImport("utils", b.createModule(.{
        .root_source_file = b.path("src/utils.zig"),
    }));
    tests.root_module.addImport("lmdbx", lmdbx_dep.module("lmdbx"));
    tests.root_module.addImport("nmslib", nmslib_mod);
 
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run VStore tests");
    test_step.dependOn(&run_tests.step);
}
