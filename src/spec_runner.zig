const std = @import("std");
const print = std.debug.print;

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
    var gfm_mode = false;
    var spec_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary_only = true;
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

    if (summary_only) {
        if (gfm_mode) {
            try printGfmSummary(allocator, use_spec_path);
        } else {
            try printSummary(allocator, use_spec_path);
        }
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

fn printGfmSummary(allocator: std.mem.Allocator, spec_path: []const u8) !void {
    const summary = try zigmark.runGfmSpecSummary(allocator, spec_path);

    print("\n{s:<50} {s:>6} {s:>6} {s:>6} {s:>10}\n", .{ "GFM Extension", "Pass", "Fail", "Total", "Time (ms)" });
    print("{s:-<76}\n", .{""});

    for (summary.sections) |s| {
        const t = s.result.total();
        if (t > 0) {
            const ms: f64 = @as(f64, @floatFromInt(s.result.time_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
            print(
                "{s:<50} {d:>6} {d:>6} {d:>6} {d:>10.2}\n",
                .{ s.section, s.result.passed, s.result.failed, t, ms },
            );
        }
    }

    const total_ms: f64 = @as(f64, @floatFromInt(summary.total_time_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    print("{s:-<76}\n", .{""});
    print("{s:<50} {d:>6} {d:>6} {d:>6} {d:>10.2}\n", .{
        "TOTAL", summary.all.passed, summary.all.failed, summary.all.total(), total_ms,
    });
}

fn printSummary(allocator: std.mem.Allocator, spec_path: []const u8) !void {
    const summary = try zigmark.runSpecSummary(allocator, spec_path);

    print("\n{s:<40} {s:>6} {s:>6} {s:>6} {s:>10}\n", .{ "Section", "Pass", "Fail", "Total", "Time (ms)" });
    print("{s:-<66}\n", .{""});

    for (summary.sections) |s| {
        const t = s.result.total();
        if (t > 0) {
            const ms: f64 = @as(f64, @floatFromInt(s.result.time_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
            print(
                "{s:<40} {d:>6} {d:>6} {d:>6} {d:>10.2}\n",
                .{ s.section, s.result.passed, s.result.failed, t, ms },
            );
        }
    }

    const total_ms: f64 = @as(f64, @floatFromInt(summary.total_time_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    print("{s:-<66}\n", .{""});
    print("{s:<40} {d:>6} {d:>6} {d:>6} {d:>10.2}\n", .{
        "TOTAL", summary.all.passed, summary.all.failed, summary.all.total(), total_ms,
    });
}
