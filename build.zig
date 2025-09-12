const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Deps
    const bench = b.dependency("anne_benchmark", .{ .target = target, .optimize = optimize }).module("anne_benchmark");

    // Main mod
    const mod = b.addModule("anne_profiler", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "benchmark",
                .module = bench,
            },
        },
    });

    // Lib export
    const lib = b.addLibrary(.{
        .name = "anne_profiler",
        .root_module = mod,
    });
    b.installArtifact(lib);

    // Testing
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.linkLibC();

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // Testing C
    const test_c_exe = b.addExecutable(.{
        .name = "c_test",
        .root_module = b.createModule(.{
            .link_libc = true,
            .target = target,
        }),
    });
    test_c_exe.root_module.addCSourceFile(.{ .file = b.path("src/test.c"), .flags = &.{"-std=c99"} });
    test_c_exe.root_module.addIncludePath(b.path("."));
    test_c_exe.root_module.linkLibrary(lib);

    const run_c_test = b.addRunArtifact(test_c_exe);
    test_step.dependOn(&run_c_test.step);
}
