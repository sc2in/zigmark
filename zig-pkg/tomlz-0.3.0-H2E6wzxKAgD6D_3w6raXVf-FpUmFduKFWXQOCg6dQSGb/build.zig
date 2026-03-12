const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tomlz = b.addModule("tomlz", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .name = "tomlz",
        .root_module = tomlz,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .root_module = tomlz,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    const fuzz = b.addModule("fuzz", .{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
    });

    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = fuzz,
    });
    fuzz_exe.linkLibC();
    b.installArtifact(fuzz_exe);
    const fuzz_compile_run = b.step("fuzz", "Build executable for fuzz testing afl-fuzz");
    fuzz_compile_run.dependOn(&fuzz_exe.step);
}
