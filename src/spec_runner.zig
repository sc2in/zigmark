const std = @import("std");
const print = std.debug.print;

const zigmark = @import("zigmark");

pub fn main() !void {
    // Use a page allocator — the spec runner is short-lived and
    // runCommonMarkSpecTests leaks intermediate strings when not
    // backed by an arena.  We don't care about reclaiming them
    // because the process exits immediately after.
    const allocator = std.heap.page_allocator;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // skip argv[0]

    var pattern: ?[]const u8 = null;
    var verbose = false;
    var number: ?usize = null;
    var summary_only = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary_only = true;
        } else if (std.mem.eql(u8, arg, "--section") or std.mem.eql(u8, arg, "-s")) {
            pattern = args.next();
        } else if (std.mem.eql(u8, arg, "--number") or std.mem.eql(u8, arg, "-n")) {
            if (args.next()) |n| {
                number = std.fmt.parseInt(usize, n, 10) catch null;
            }
        }
    }

    if (summary_only) {
        try printSummary(allocator);
        return;
    }

    const result = try zigmark.runCommonMarkSpecTests(allocator, "./src/markdown/spec.txt", .{
        .pattern = pattern,
        .normalize = true,
        .verbose = verbose,
        .number = number,
    });

    const total = result.passed + result.failed + result.errors;
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

fn printSummary(allocator: std.mem.Allocator) !void {
    const sections = [_][]const u8{
        "ATX",      "Setext",    "Thematic",   "Paragraph", "Blank",
        "Indented", "Fenced",    "Blockquote", "List",      "Backslash",
        "Entity",   "Code span", "Emphasis",   "Link",      "Image",
        "Autolink", "Raw HTML",  "Hard line",  "Soft line", "Textual",
    };

    print("\n{s:<25} {s:>6} {s:>6} {s:>6} {s:>10}\n", .{ "Section", "Pass", "Fail", "Total", "Time (ms)" });
    print("{s:-<56}\n", .{""});

    var total_passed: usize = 0;
    var total_failed: usize = 0;
    var total_errors: usize = 0;
    var total_time_ns: i128 = 0;

    for (sections) |section| {
        const r = try zigmark.runCommonMarkSpecTests(allocator, "./src/markdown/spec.txt", .{
            .pattern = section,
            .normalize = true,
            .verbose = false,
        });
        const total = r.passed + r.failed + r.errors;
        const section_ms: f64 = @as(f64, @floatFromInt(r.time_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
        total_time_ns += r.time_ns;
        if (total > 0) {
            print(
                "{s:<25} {d:>6} {d:>6} {d:>6} {d:>10.2}\n",
                .{ section, r.passed, r.failed, total, section_ms },
            );
        }
        total_passed += r.passed;
        total_failed += r.failed;
        total_errors += r.errors;
    }

    const total_ms: f64 = @as(f64, @floatFromInt(total_time_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    print("{s:-<56}\n", .{""});
    print("{s:<25} {d:>6} {d:>6} {d:>6} {d:>10.2}\n", .{
        "TOTAL", total_passed, total_failed, total_passed + total_failed + total_errors, total_ms,
    });
}
