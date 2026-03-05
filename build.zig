const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tomlz = b.dependency("tomlz", .{
        .target = target,
        .optimize = optimize,
    });

    const yaml = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });
    const mvzr = b.dependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    });

    const mecha = b.dependency("mecha", .{});
    const dt = b.dependency("datetime", .{
        .target = target,
        .optimize = optimize,
    });

    const zigmark = b.addModule("zigmark", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    zigmark.addImport("tomlz", tomlz.module("tomlz"));
    zigmark.addImport("yaml", yaml.module("yaml"));
    zigmark.addImport("mvzr", mvzr.module("mvzr"));
    zigmark.addImport("mecha", mecha.module("mecha"));
    zigmark.addImport("dt", dt.module("datetime"));
    const exe = b.addExecutable(.{
        .name = "zigmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigmark", .module = zigmark },
            },
        }),
    });
    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const mod_tests = b.addTest(.{
        .root_module = zigmark,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
