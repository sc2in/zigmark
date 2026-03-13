const std = @import("std");

const clap = @import("clap");
const zigmark = @import("zigmark");
const AST = zigmark.AST;
const version = zigmark.version;

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    // All allocations are tracked by the GPA; doc.deinit() frees
    // everything the parser and renderers allocate.
    const alloc = gpa;

    // ── CLI definition ───────────────────────────────────────────────────────
    const params = comptime clap.parseParamsComptime(
        \\-h, --help               Display this help and exit.
        \\-v, --version            Print version and exit.
        \\-f, --format <str>       Output format: "html" (default), "ast", or "ai".
        \\-o, --output <str>       Write output to FILE instead of stdout.
        \\<str>                    Input markdown file (reads stdin if omitted).
        \\
    );

    var diag = clap.Diagnostic{};
    var iter = try std.process.argsWithAllocator(gpa);
    defer iter.deinit();

    // skip argv[0]
    _ = iter.next();

    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        var buf: [4096]u8 = undefined;
        var err_writer = std.Io.Writer.fixed(&buf);
        diag.report(&err_writer, err) catch {};
        std.debug.print("{s}", .{err_writer.buffered()});
        return err;
    };
    defer res.deinit();

    // ── Help ─────────────────────────────────────────────────────────────────
    if (res.args.help != 0) {
        var buf: [4096]u8 = undefined;
        var help_writer = std.Io.Writer.fixed(&buf);
        clap.help(&help_writer, clap.Help, &params, .{}) catch {};
        std.debug.print(
            \\zigmark {s} — CommonMark-compliant Markdown parser
            \\
            \\Usage: zigmark [OPTIONS] [FILE]
            \\
            \\{s}
        , .{ version, help_writer.buffered() });
        return;
    }

    // ── Version ──────────────────────────────────────────────────────────────
    if (res.args.version != 0) {
        std.debug.print("zigmark {s}\n", .{version});
        return;
    }

    // ── Read input ───────────────────────────────────────────────────────────
    const input = blk: {
        if (res.positionals[0]) |path| {
            const file = std.fs.cwd().openFile(path, .{}) catch |err| {
                std.debug.print("error: cannot open '{s}': {}\n", .{ path, err });
                return err;
            };
            defer file.close();
            break :blk file.readToEndAlloc(alloc, std.math.maxInt(usize)) catch |err| {
                std.debug.print("error: failed to read '{s}': {}\n", .{ path, err });
                return err;
            };
        } else {
            const stdin = std.fs.File.stdin();
            break :blk stdin.readToEndAlloc(alloc, std.math.maxInt(usize)) catch |err| {
                std.debug.print("error: failed to read stdin: {}\n", .{err});
                return err;
            };
        }
    };
    defer alloc.free(input);

    // ── Resolve format ───────────────────────────────────────────────────────
    const format: []const u8 = if (res.args.format) |f| f else "html";

    // ── Parse ────────────────────────────────────────────────────────────────
    var parser = zigmark.Parser.init();
    var doc = parser.parseMarkdown(alloc, input) catch |err| {
        std.debug.print("error: failed to parse markdown: {}\n", .{err});
        return err;
    };
    defer doc.deinit(alloc);

    // ── Output ───────────────────────────────────────────────────────────────
    const out_file = getOutputFile(res.args.output);
    defer closeOutput(res.args.output, out_file);
    var out_buf: [8192]u8 = undefined;
    var writer = out_file.writer(&out_buf);

    if (std.mem.eql(u8, format, "ast")) {
        const ast_output = zigmark.ASTRenderer.render(alloc, doc) catch |err| {
            std.debug.print("error: failed to render AST: {}\n", .{err});
            return err;
        };
        defer alloc.free(ast_output);
        writer.interface.writeAll(ast_output) catch {};
        writer.interface.flush() catch {};
    } else if (std.mem.eql(u8, format, "html")) {
        const html = zigmark.HTMLRenderer.render(alloc, doc) catch |err| {
            std.debug.print("error: failed to render HTML: {}\n", .{err});
            return err;
        };
        defer alloc.free(html);
        writer.interface.writeAll(html) catch {};
        writer.interface.flush() catch {};
    } else if (std.mem.eql(u8, format, "ai")) {
        const a = zigmark.AIRenderer.render(alloc, doc) catch |err| {
            std.debug.print("error: failed to render AI AST: {}\n", .{err});
            return err;
        };
        defer alloc.free(a);
        writer.interface.writeAll(a) catch {};
        writer.interface.flush() catch {};
    } else {
        std.debug.print("error: unknown format '{s}'. Use 'html' or 'ast'.\n", .{format});
        return error.InvalidArgument;
    }
}

// ── Output helpers ───────────────────────────────────────────────────────────

fn getOutputFile(output_path: ?[]const u8) std.fs.File {
    if (output_path) |path| {
        return std.fs.cwd().createFile(path, .{}) catch |err| {
            std.debug.print("error: cannot create '{s}': {}\n", .{ path, err });
            std.process.exit(1);
        };
    } else {
        return std.fs.File.stdout();
    }
}

fn closeOutput(output_path: ?[]const u8, file: std.fs.File) void {
    if (output_path != null) {
        file.close();
    }
}
