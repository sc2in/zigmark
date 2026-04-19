const std = @import("std");

const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // CommonMark spec dependency for spec.txt
    const commonmark_spec = b.dependency("commonmark_spec", .{});
    const spec_txt_path = commonmark_spec.path("spec.txt");
    // GFM spec dependency (cmark-gfm); spec lives at test/spec.txt inside the repo
    const gfm_spec = b.dependency("gfm_spec", .{});
    const gfm_spec_txt_path = gfm_spec.path("test/spec.txt");

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
    const pozeiden_dep = b.lazyDependency("pozeiden", .{
        .target = target,
        .optimize = optimize,
    });
    const pozeiden_module = if (pozeiden_dep) |dep|
        dep.module("pozeiden")
    else
        b.addModule("pozeiden-stub", .{
            .root_source_file = b.path("src/noop_mermaid.zig"),
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
    // Add the spec file paths as build options
    options.addOption([]const u8, "spec_file_path", spec_txt_path.getPath(b));
    options.addOption([]const u8, "gfm_spec_file_path", gfm_spec_txt_path.getPath(b));

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

    // The shared library needs its own module instance.  When the exe and .so
    // share a module, lld rejects the build because the .so's PIC TLS access
    // calls __tls_get_addr (provided by glibc) but the exe is fully static.
    // Fixing that by adding linkLibC() compiles the module into the exe AND
    // makes it dynamically linked against libc — but the .so is still never
    // actually loaded at runtime because all zigmark symbols are already
    // satisfied by the exe's own compiled copy.  Net result: larger exe with
    // a libc dependency and no size saving.
    //
    // The root cause is that Zig's module system always compiles code inline;
    // there is no "header-only import" concept.  The exe must either (a) keep
    // the module compiled in (current approach, self-contained 4 MB binary) or
    // (b) be rewritten to use extern C API declarations so @import("zigmark")
    // is never used.  (a) is the right trade-off for a CLI tool.
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
                .{ .name = "pozeiden", .module = pozeiden_module },
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
    const test_step = b.step("test", "Run unit tests + CommonMark spec + GFM spec");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // ── Fuzz tests ────────────────────────────────────────────────────────────
    // Run once (smoke test):          zig build fuzz
    // Coverage-guided fuzzing:        zig build fuzz --fuzz
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "zigmark", .module = zigmark },
            },
        }),
        // The self-hosted backend omits sanitizer-coverage sections, leaving
        // the pcs array empty and causing a panic in Build/Fuzz.zig:429.
        // LLVM emits the required __sancov_pcs1/__sancov_cntrs sections.
        .use_llvm = true,
    });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    const fuzz_step = b.step("fuzz", "Run fuzz tests (append --fuzz to activate coverage-guided fuzzing)");
    fuzz_step.dependOn(&run_fuzz.step);

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

    // ── zig build spec ────────────────────────────────────────────────────────
    // Side-by-side CommonMark + GFM summaries; GFM supersedes where they conflict.
    // GFM summary runs after CommonMark so output is sequential.
    const spec_step = b.step("spec", "Run CommonMark + GFM spec tests side by side (GFM supersedes)");
    const spec_cmark_summary = b.addRunArtifact(spec_exe);
    spec_cmark_summary.addArgs(&.{ "--summary", "--spec", spec_txt_path.getPath(b) });
    const spec_gfm_summary = b.addRunArtifact(spec_exe);
    spec_gfm_summary.addArgs(&.{ "--summary", "--gfm", "--spec", gfm_spec_txt_path.getPath(b) });
    spec_gfm_summary.step.dependOn(&spec_cmark_summary.step);
    spec_step.dependOn(&spec_gfm_summary.step);

    // ── zig build cmark ───────────────────────────────────────────────────────
    const cmark_step = b.step("cmark", "Run CommonMark spec tests (summary table)");
    const cmark_summary = b.addRunArtifact(spec_exe);
    cmark_summary.addArgs(&.{ "--summary", "--spec", spec_txt_path.getPath(b) });
    cmark_step.dependOn(&cmark_summary.step);

    // zig build cmark-verbose -- all CommonMark tests with failure details
    const cmark_verbose_step = b.step("cmark-verbose", "Run all CommonMark spec tests with failure details");
    const cmark_verbose = b.addRunArtifact(spec_exe);
    cmark_verbose.addArgs(&.{ "--verbose", "--spec", spec_txt_path.getPath(b) });
    cmark_verbose_step.dependOn(&cmark_verbose.step);

    // Per-section steps: zig build cmark-atx, cmark-emphasis, etc.
    const section_defs = .{
        .{ "atx", "ATX", "Run ATX heading spec tests" },
        .{ "setext", "Setext", "Run setext heading spec tests" },
        .{ "thematic", "Thematic", "Run thematic break spec tests" },
        .{ "paragraph", "Paragraph", "Run paragraph spec tests" },
        .{ "blank", "Blank", "Run blank line spec tests" },
        .{ "indented", "Indented", "Run indented code spec tests" },
        .{ "fenced", "Fenced", "Run fenced code spec tests" },
        .{ "blockquote", "Blockquote", "Run blockquote spec tests" },
        .{ "list", "List", "Run list spec tests" },
        .{ "backslash", "Backslash", "Run backslash escape spec tests" },
        .{ "entity", "Entity", "Run entity spec tests" },
        .{ "codespan", "Code span", "Run code span spec tests" },
        .{ "emphasis", "Emphasis", "Run emphasis spec tests" },
        .{ "links", "Link", "Run link spec tests" },
        .{ "image", "Image", "Run image spec tests" },
        .{ "autolink", "Autolink", "Run autolink spec tests" },
        .{ "html", "Raw HTML", "Run raw HTML spec tests" },
        .{ "hardline", "Hard line", "Run hard line break spec tests" },
        .{ "softline", "Soft line", "Run soft line break spec tests" },
        .{ "textual", "Textual", "Run textual content spec tests" },
    };

    inline for (section_defs) |def| {
        const step = b.step("cmark-" ++ def[0], def[2]);
        const run = b.addRunArtifact(spec_exe);
        run.addArgs(&.{ "--section", def[1], "--verbose", "--spec", spec_txt_path.getPath(b) });
        step.dependOn(&run.step);
    }

    // ── zig build gfm ─────────────────────────────────────────────────────────
    const gfm_step = b.step("gfm", "Run GFM extension spec tests (summary table)");
    const gfm_summary = b.addRunArtifact(spec_exe);
    gfm_summary.addArgs(&.{ "--summary", "--gfm", "--spec", gfm_spec_txt_path.getPath(b) });
    gfm_step.dependOn(&gfm_summary.step);

    // zig build gfm-verbose -- all GFM extension tests with failure details
    const gfm_verbose_step = b.step("gfm-verbose", "Run all GFM extension spec tests with failure details");
    const gfm_verbose = b.addRunArtifact(spec_exe);
    gfm_verbose.addArgs(&.{ "--verbose", "--gfm", "--spec", gfm_spec_txt_path.getPath(b) });
    gfm_verbose_step.dependOn(&gfm_verbose.step);

    // Per-extension steps: zig build gfm-tables, gfm-strikethrough, etc.
    const gfm_section_defs = .{
        .{ "gfm-tables", "Tables (extension)", "Run GFM tables spec tests" },
        .{ "gfm-tasklist", "Task list items (extension)", "Run GFM task list items spec tests" },
        .{ "gfm-strikethrough", "Strikethrough (extension)", "Run GFM strikethrough spec tests" },
        .{ "gfm-autolinks", "Autolinks (extension)", "Run GFM autolinks spec tests" },
        .{ "gfm-rawhtml", "Disallowed Raw HTML (extension)", "Run GFM disallowed raw HTML spec tests" },
    };

    inline for (gfm_section_defs) |def| {
        const step = b.step(def[0], def[2]);
        const run = b.addRunArtifact(spec_exe);
        run.addArgs(&.{ "--section", def[1], "--verbose", "--spec", gfm_spec_txt_path.getPath(b) });
        step.dependOn(&run.step);
    }

    // ── spec runs wired into zig build test ───────────────────────────────────
    // Use --quiet: silent on full pass; dumps the table only on a regression.
    // The verbose summary table is reserved for `zig build spec`.
    const spec_check_cmark = b.addRunArtifact(spec_exe);
    spec_check_cmark.addArgs(&.{ "--quiet", "--spec", spec_txt_path.getPath(b) });
    const spec_check_gfm = b.addRunArtifact(spec_exe);
    spec_check_gfm.addArgs(&.{ "--quiet", "--gfm", "--spec", gfm_spec_txt_path.getPath(b) });
    spec_check_gfm.step.dependOn(&spec_check_cmark.step);
    test_step.dependOn(&spec_check_gfm.step);

    // ── WASM build ───────────────────────────────────────────────────────────

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
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
