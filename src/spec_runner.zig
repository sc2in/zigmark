const std = @import("std");
const print = std.debug.print;

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .tokenizer, .level = .warn },
        .{ .scope = .parser, .level = .warn },
    },
};

const zigmark = @import("zigmark");

const default_spec_path = "./src/markdown/spec.txt";

pub fn main() !void {
    // Use a page allocator — the spec runner is short-lived and
    // runs many parse/render cycles.  A page allocator avoids the
    // overhead of tracking individual allocations.
    const allocator = std.heap.page_allocator;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // skip argv[0]

    var pattern: ?[]const u8 = null;
    var verbose = false;
    var number: ?usize = null;
    var summary_only = false;
    var quiet = false;
    var gfm_mode = false;
    var spec_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary_only = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--gfm")) {
            gfm_mode = true;
        } else if (std.mem.eql(u8, arg, "--section") or std.mem.eql(u8, arg, "-s")) {
            pattern = args.next();
        } else if (std.mem.eql(u8, arg, "--number") or std.mem.eql(u8, arg, "-n")) {
            if (args.next()) |n| {
                number = std.fmt.parseInt(usize, n, 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--spec")) {
            spec_path = args.next();
        }
    }

    const use_spec_path = spec_path orelse default_spec_path;

    // --quiet: silent on full pass; dump the full table only on failure.
    if (quiet) {
        const failed: usize = if (gfm_mode)
            try quietCheck(allocator, use_spec_path, true)
        else
            try quietCheck(allocator, use_spec_path, false);
        if (failed > 0) std.process.exit(1);
        return;
    }

    if (summary_only) {
        const failed: usize = if (gfm_mode)
            try printGfmSummary(allocator, use_spec_path)
        else
            try printSummary(allocator, use_spec_path);
        if (failed > 0) std.process.exit(1);
        return;
    }

    // In GFM mode without a specific --section, run all GFM extension sections.
    if (gfm_mode and pattern == null) {
        var total_result = zigmark.TestResult{};
        for (zigmark.gfm_sections) |section| {
            const r = try zigmark.runCommonMarkSpecTests(allocator, use_spec_path, .{
                .pattern = section,
                .normalize = true,
                .verbose = verbose,
                .number = number,
                .gfm = true,
            });
            total_result.passed += r.passed;
            total_result.failed += r.failed;
            total_result.errors += r.errors;
            total_result.skipped += r.skipped;
            total_result.time_ns += r.time_ns;
        }
        const total = total_result.total();
        print("\nGFM extensions — Passed: {d}/{d}", .{ total_result.passed, total });
        if (total_result.errors > 0) print("  Errors: {d}", .{total_result.errors});
        print("\n", .{});
        if (total_result.failed > 0) std.process.exit(1);
        return;
    }

    const result = try zigmark.runCommonMarkSpecTests(allocator, use_spec_path, .{
        .pattern = pattern,
        .normalize = true,
        .verbose = verbose,
        .number = number,
        .gfm = gfm_mode,
    });

    const total = result.total();
    print("\n", .{});
    if (pattern) |p| {
        print("Section filter: {s}\n", .{p});
    }
    print("Passed: {d}/{d}", .{ result.passed, total });
    if (result.errors > 0) {
        print("  Errors: {d}", .{result.errors});
    }
    print("\n", .{});

    if (result.failed > 0) {
        std.process.exit(1);
    }
}

/// Quiet check: run the full suite, emit nothing on success.
/// On failure, print the full section table then exit 1.
fn quietCheck(allocator: std.mem.Allocator, spec_path: []const u8, gfm: bool) !usize {
    if (gfm) {
        const summary = try zigmark.runGfmSpecSummary(allocator, spec_path);
        if (summary.all.failed == 0) return 0;
        _ = try printGfmSummary(allocator, spec_path);
        return summary.all.failed;
    } else {
        const summary = try zigmark.runSpecSummary(allocator, spec_path);
        if (summary.all.failed == 0) return 0;
        _ = try printSummary(allocator, spec_path);
        return summary.all.failed;
    }
}

fn printGfmSummary(allocator: std.mem.Allocator, spec_path: []const u8) !usize {
    const summary = try zigmark.runGfmSpecSummary(allocator, spec_path);
    try printResultsTable(allocator, "GFM Extension", summary.sections[0..], summary.all, summary.total_time_ns);
    return summary.all.failed;
}

fn printSummary(allocator: std.mem.Allocator, spec_path: []const u8) !usize {
    const summary = try zigmark.runSpecSummary(allocator, spec_path);
    try printResultsTable(allocator, "Section", summary.sections[0..], summary.all, summary.total_time_ns);
    return summary.all.failed;
}

/// Build a GFM table from spec results using the AST API and render it to
/// stdout with the Markdown renderer.  This dog-foods `Document.Mutate`,
/// `TableRow.fromStrings`, and `MarkdownRenderer` end-to-end.
fn printResultsTable(
    allocator: std.mem.Allocator,
    section_label: []const u8,
    sections: []const zigmark.SectionResult,
    all: zigmark.TestResult,
    total_time_ns: i128,
) !void {
    var doc = zigmark.AST.Document.init(allocator);
    defer doc.deinit(allocator);
    const m = doc.edit();

    // Build the GFM table.
    var table = zigmark.AST.Table.init(allocator);
    errdefer table.deinit(allocator);

    // Column alignments: section label (left), Pass/Fail/Total (right), Time ms (right).
    try table.alignments.append(allocator, .left);
    try table.alignments.append(allocator, .right);
    try table.alignments.append(allocator, .right);
    try table.alignments.append(allocator, .right);
    try table.alignments.append(allocator, .right);

    // Header row.
    table.header.deinit(allocator);
    table.header = try zigmark.AST.TableRow.fromStrings(
        allocator,
        &.{ section_label, "Pass", "Fail", "Total", "Time (ms)" },
    );

    // One row per non-empty section.
    for (sections) |s| {
        const t = s.result.total();
        if (t == 0) continue;
        const ms: f64 = @as(f64, @floatFromInt(s.result.time_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));

        const pass_s  = try std.fmt.allocPrint(allocator, "{d}", .{s.result.passed});
        defer allocator.free(pass_s);
        const fail_s  = try std.fmt.allocPrint(allocator, "{d}", .{s.result.failed});
        defer allocator.free(fail_s);
        const total_s = try std.fmt.allocPrint(allocator, "{d}", .{t});
        defer allocator.free(total_s);
        const ms_s    = try std.fmt.allocPrint(allocator, "{d:.2}", .{ms});
        defer allocator.free(ms_s);

        const row = try zigmark.AST.TableRow.fromStrings(
            allocator,
            &.{ s.section, pass_s, fail_s, total_s, ms_s },
        );
        try table.body.append(allocator, row);
    }

    // TOTAL row (bold via inline Markdown in the cell text).
    {
        const total_ms: f64 = @as(f64, @floatFromInt(total_time_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
        const pass_s  = try std.fmt.allocPrint(allocator, "{d}", .{all.passed});
        defer allocator.free(pass_s);
        const fail_s  = try std.fmt.allocPrint(allocator, "{d}", .{all.failed});
        defer allocator.free(fail_s);
        const total_s = try std.fmt.allocPrint(allocator, "{d}", .{all.total()});
        defer allocator.free(total_s);
        const ms_s    = try std.fmt.allocPrint(allocator, "{d:.2}", .{total_ms});
        defer allocator.free(ms_s);

        const row = try zigmark.AST.TableRow.fromStrings(
            allocator,
            &.{ "TOTAL", pass_s, fail_s, total_s, ms_s },
        );
        try table.body.append(allocator, row);
    }

    try m.appendBlock(allocator, .{ .table = table });

    const rendered = try zigmark.MarkdownRenderer.render(allocator, doc);
    defer allocator.free(rendered);
    print("\n{s}\n", .{rendered});
}
