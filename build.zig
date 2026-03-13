const std = @import("std");

const zon = @import("build.zig.zon");

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
    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    const options = b.addOptions();
    // Version priority: -Dversion flag > git describe > build.zig.zon
    // The flag lets Nix (and other sandboxed builds) inject the version
    // without requiring git to be present in the build environment.
    const version = b.option([]const u8, "version", "Override version string") orelse blk: {
        var exit_code: u8 = undefined;
        const git_describe = b.runAllowFail(
            &.{ "git", "describe", "--tags", "--always" },
            &exit_code,
            .Ignore,
        ) catch "";
        break :blk if (git_describe.len > 0) trimLeadingV(git_describe) else zon.version;
    };
    options.addOption([]const u8, "version", version);

    const zigmark = b.addModule("zigmark", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zigmark.addOptions("config", options);
    zigmark.addImport("tomlz", tomlz.module("tomlz"));
    zigmark.addImport("yaml", yaml.module("yaml"));
    zigmark.addImport("mvzr", mvzr.module("mvzr"));
    zigmark.addImport("mecha", mecha.module("mecha"));
    zigmark.addImport("dt", dt.module("datetime"));

    // The shared library needs its own module instance so the exe doesn't
    // get implicitly linked against the .so (which causes TLS / undefined
    // symbol errors in ReleaseSafe).
    const zigmark_lib = b.addModule("zigmark_lib", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zigmark_lib.addOptions("config", options);
    zigmark_lib.addImport("tomlz", tomlz.module("tomlz"));
    zigmark_lib.addImport("yaml", yaml.module("yaml"));
    zigmark_lib.addImport("mvzr", mvzr.module("mvzr"));
    zigmark_lib.addImport("mecha", mecha.module("mecha"));
    zigmark_lib.addImport("dt", dt.module("datetime"));

    const exe = b.addExecutable(.{
        .name = "zigmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigmark", .module = zigmark },
                .{ .name = "clap", .module = clap_dep.module("clap") },
            },
        }),
    });
    const lib = b.addLibrary(.{
        .name = "zigmark",
        .root_module = zigmark_lib,
        .linkage = .dynamic,
    });
    b.installArtifact(exe);
    b.installArtifact(lib);
    // Install the C header alongside the shared library.
    // NOTE: Zig 0.15's -femit-h silently produces nothing on the LLVM
    // backend, so we maintain the header by hand for now.
    b.installFile("include/zigmark.h", "include/zigmark.h");

    const docs_step = b.step("docs", "Build documentation");
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&docs.step);

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

    // ── WASM build ───────────────────────────────────────────────────────────

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_optimize = .ReleaseSmall;

    const wasm_tomlz = b.dependency("tomlz", .{ .target = wasm_target, .optimize = wasm_optimize });
    const wasm_yaml = b.dependency("yaml", .{ .target = wasm_target, .optimize = wasm_optimize });
    const wasm_mvzr = b.dependency("mvzr", .{ .target = wasm_target, .optimize = wasm_optimize });
    const wasm_mecha = b.dependency("mecha", .{});
    const wasm_dt = b.dependency("datetime", .{ .target = wasm_target, .optimize = wasm_optimize });

    const zigmark_wasm_mod = b.addModule("zigmark_wasm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
    });
    zigmark_wasm_mod.addOptions("config", options);
    zigmark_wasm_mod.addImport("tomlz", wasm_tomlz.module("tomlz"));
    zigmark_wasm_mod.addImport("yaml", wasm_yaml.module("yaml"));
    zigmark_wasm_mod.addImport("mvzr", wasm_mvzr.module("mvzr"));
    zigmark_wasm_mod.addImport("mecha", wasm_mecha.module("mecha"));
    zigmark_wasm_mod.addImport("dt", wasm_dt.module("datetime"));

    const wasm_lib = b.addExecutable(.{
        .name = "zigmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/wasm/zigmark-wasm.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
            .imports = &.{
                .{ .name = "zigmark", .module = zigmark_wasm_mod },
            },
        }),
    });
    wasm_lib.entry = .disabled;
    wasm_lib.root_module.export_symbol_names = &.{
        "render_html",
        "render_ast",
        "render_ai",
        "result_len",
        "alloc_buf",
        "free_buf",
        "version_ptr",
        "version_len",
    };

    const wasm_step = b.step("wasm", "Build the WASM module (examples/wasm/)");
    const install_wasm = b.addInstallArtifact(wasm_lib, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });
    // Also copy the demo HTML alongside the .wasm
    const install_html = b.addInstallFile(b.path("examples/wasm/index.html"), "wasm/index.html");
    wasm_step.dependOn(&install_wasm.step);
    wasm_step.dependOn(&install_html.step);
}

/// Strip a leading "v" and trailing whitespace from a git describe string,
/// e.g. "v0.2.0\n" → "0.2.0", "v0.2.0-3-gabcdef\n" → "0.2.0-3-gabcdef".
fn trimLeadingV(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    return if (trimmed.len > 0 and trimmed[0] == 'v') trimmed[1..] else trimmed;
}
