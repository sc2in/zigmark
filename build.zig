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
    const lib = b.addLibrary(.{
        .name = "zigmark",
        .root_module = zigmark,
        .linkage = .dynamic,
    });
    b.installArtifact(exe);
    b.installArtifact(lib);

    const docs_step = b.step("docs", "Build documentation");
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&docs.step);
    b.getInstallStep().dependOn(docs_step);

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

    // ── Spec runner ──────────────────────────────────────────────────────────

    const spec_exe = b.addExecutable(.{
        .name = "spec-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spec_runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigmark", .module = zigmark },
            },
        }),
    });

    // zig build spec -- summary table of all sections
    const spec_step = b.step("spec", "Run CommonMark spec tests (summary table)");
    const spec_summary = b.addRunArtifact(spec_exe);
    spec_summary.addArgs(&.{"--summary"});
    spec_step.dependOn(&spec_summary.step);

    // zig build spec-verbose -- all tests with failure details
    const spec_verbose_step = b.step("spec-verbose", "Run all CommonMark spec tests with failure details");
    const spec_verbose = b.addRunArtifact(spec_exe);
    spec_verbose.addArgs(&.{"--verbose"});
    spec_verbose_step.dependOn(&spec_verbose.step);

    // Per-section steps: zig build spec-emphasis, spec-links, etc.
    const section_defs = .{
        .{ "spec-atx", "ATX", "Run ATX heading spec tests" },
        .{ "spec-setext", "Setext", "Run setext heading spec tests" },
        .{ "spec-thematic", "Thematic", "Run thematic break spec tests" },
        .{ "spec-paragraph", "Paragraph", "Run paragraph spec tests" },
        .{ "spec-blank", "Blank", "Run blank line spec tests" },
        .{ "spec-indented", "Indented", "Run indented code spec tests" },
        .{ "spec-fenced", "Fenced", "Run fenced code spec tests" },
        .{ "spec-blockquote", "Blockquote", "Run blockquote spec tests" },
        .{ "spec-list", "List", "Run list spec tests" },
        .{ "spec-backslash", "Backslash", "Run backslash escape spec tests" },
        .{ "spec-entity", "Entity", "Run entity spec tests" },
        .{ "spec-codespan", "Code span", "Run code span spec tests" },
        .{ "spec-emphasis", "Emphasis", "Run emphasis spec tests" },
        .{ "spec-links", "Link", "Run link spec tests" },
        .{ "spec-image", "Image", "Run image spec tests" },
        .{ "spec-autolink", "Autolink", "Run autolink spec tests" },
        .{ "spec-rawhtml", "Raw HTML", "Run raw HTML spec tests" },
        .{ "spec-hardline", "Hard line", "Run hard line break spec tests" },
        .{ "spec-softline", "Soft line", "Run soft line break spec tests" },
        .{ "spec-textual", "Textual", "Run textual content spec tests" },
    };

    inline for (section_defs) |def| {
        const step = b.step(def[0], def[2]);
        const run = b.addRunArtifact(spec_exe);
        run.addArgs(&.{ "--section", def[1], "--verbose" });
        step.dependOn(&run.step);
    }
}
