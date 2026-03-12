const std = @import("std");

const clap = @import("clap");
const zigmark = @import("zigmark");
const AST = zigmark.AST;

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    // Use an arena for parsing since the parser leaks some internal
    // allocations that doc.deinit does not cover.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // ── CLI definition ───────────────────────────────────────────────────────
    const params = comptime clap.parseParamsComptime(
        \\-h, --help          Display this help and exit.
        \\-f, --format <str>  Output format: "html" (default) or "ast".
        \\<str>               Input markdown file (reads stdin if omitted).
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
        std.debug.print("Usage: zigmark [OPTIONS] [FILE]\n\n{s}", .{help_writer.buffered()});
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

    // ── Parse ────────────────────────────────────────────────────────────────
    var parser = zigmark.Parser.init();
    const doc = parser.parseMarkdown(alloc, input) catch |err| {
        std.debug.print("error: failed to parse markdown: {}\n", .{err});
        return err;
    };

    // ── Output ───────────────────────────────────────────────────────────────
    const format: []const u8 = if (res.args.format) |f| f else "html";

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);

    if (std.mem.eql(u8, format, "ast")) {
        printAstTree(&stdout_writer.interface, doc) catch |err| {
            std.debug.print("error: failed to write AST: {}\n", .{err});
            return err;
        };
        stdout_writer.interface.flush() catch {};
    } else if (std.mem.eql(u8, format, "html")) {
        const html = zigmark.HTMLRenderer.render(alloc, doc) catch |err| {
            std.debug.print("error: failed to render HTML: {}\n", .{err});
            return err;
        };
        stdout_writer.interface.writeAll(html) catch {};
        stdout_writer.interface.flush() catch {};
    } else {
        std.debug.print("error: unknown format '{s}'. Use 'html' or 'ast'.\n", .{format});
        return error.InvalidArgument;
    }
}

// ── AST tree printer ─────────────────────────────────────────────────────────

fn printAstTree(writer: *std.Io.Writer, doc: AST.Document) !void {
    try writer.writeAll("Document\n");
    for (doc.children.items, 0..) |block, i| {
        const is_last = i == doc.children.items.len - 1;
        try printBlock(writer, block, "", is_last);
    }
}

fn printBlock(writer: *std.Io.Writer, block: AST.Block, prefix: []const u8, is_last: bool) !void {
    const connector: []const u8 = if (is_last) "└── " else "├── ";
    const child_prefix_ext: []const u8 = if (is_last) "    " else "│   ";

    try writer.writeAll(prefix);
    try writer.writeAll(connector);

    switch (block) {
        .paragraph => |para| {
            try writer.writeAll("Paragraph\n");
            var buf: [256]u8 = undefined;
            const new_prefix = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, child_prefix_ext }) catch prefix;
            for (para.children.items, 0..) |inl, j| {
                const last = j == para.children.items.len - 1;
                try printInline(writer, inl, new_prefix, last);
            }
        },
        .heading => |h| {
            try writer.print("Heading (level={d})\n", .{h.level});
            var buf: [256]u8 = undefined;
            const new_prefix = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, child_prefix_ext }) catch prefix;
            for (h.children.items, 0..) |inl, j| {
                const last = j == h.children.items.len - 1;
                try printInline(writer, inl, new_prefix, last);
            }
        },
        .code_block => |cb| {
            try writer.print("CodeBlock ({d} bytes)\n", .{cb.content.len});
        },
        .fenced_code_block => |fcb| {
            if (fcb.language) |lang| {
                try writer.print("FencedCodeBlock lang=\"{s}\" ({d} bytes)\n", .{ lang, fcb.content.len });
            } else {
                try writer.print("FencedCodeBlock ({d} bytes)\n", .{fcb.content.len});
            }
        },
        .blockquote => |bq| {
            try writer.writeAll("Blockquote\n");
            var buf: [256]u8 = undefined;
            const new_prefix = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, child_prefix_ext }) catch prefix;
            for (bq.children.items, 0..) |child, j| {
                const last = j == bq.children.items.len - 1;
                try printBlock(writer, child, new_prefix, last);
            }
        },
        .list => |lst| {
            const kind: []const u8 = if (lst.type == .ordered) "ordered" else "unordered";
            const tight_str: []const u8 = if (lst.tight) "tight" else "loose";
            if (lst.start) |start| {
                try writer.print("List ({s}, {s}, start={d})\n", .{ kind, tight_str, start });
            } else {
                try writer.print("List ({s}, {s})\n", .{ kind, tight_str });
            }
            var buf: [256]u8 = undefined;
            const new_prefix = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, child_prefix_ext }) catch prefix;
            for (lst.items.items, 0..) |item, j| {
                const last = j == lst.items.items.len - 1;
                const item_conn: []const u8 = if (last) "└── " else "├── ";
                const item_ext: []const u8 = if (last) "    " else "│   ";
                try writer.writeAll(new_prefix);
                try writer.writeAll(item_conn);
                try writer.writeAll("ListItem\n");
                var buf2: [256]u8 = undefined;
                const item_prefix = std.fmt.bufPrint(&buf2, "{s}{s}", .{ new_prefix, item_ext }) catch new_prefix;
                for (item.children.items, 0..) |child, k| {
                    const child_last = k == item.children.items.len - 1;
                    try printBlock(writer, child, item_prefix, child_last);
                }
            }
        },
        .thematic_break => |tb| {
            try writer.print("ThematicBreak ('{c}')\n", .{tb.char});
        },
        .html_block => |hb| {
            try writer.print("HtmlBlock ({d} bytes)\n", .{hb.content.len});
        },
        .footnote_definition => |fd| {
            try writer.print("FootnoteDefinition [{s}]\n", .{fd.label});
            var buf: [256]u8 = undefined;
            const new_prefix = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, child_prefix_ext }) catch prefix;
            for (fd.children.items, 0..) |child, j| {
                const last = j == fd.children.items.len - 1;
                try printBlock(writer, child, new_prefix, last);
            }
        },
    }
}

fn printInline(writer: *std.Io.Writer, inl: AST.Inline, prefix: []const u8, is_last: bool) !void {
    const connector: []const u8 = if (is_last) "└── " else "├── ";
    const child_prefix_ext: []const u8 = if (is_last) "    " else "│   ";

    try writer.writeAll(prefix);
    try writer.writeAll(connector);

    switch (inl) {
        .text => |t| {
            const max_len: usize = 60;
            if (t.content.len > max_len) {
                try writer.print("Text \"{s}...\"\n", .{t.content[0..max_len]});
            } else {
                try writer.print("Text \"{s}\"\n", .{t.content});
            }
        },
        .emphasis => |em| {
            try writer.print("Emphasis ('{c}')\n", .{em.marker});
            var buf: [256]u8 = undefined;
            const new_prefix = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, child_prefix_ext }) catch prefix;
            for (em.children.items, 0..) |child, j| {
                const last = j == em.children.items.len - 1;
                try printInline(writer, child, new_prefix, last);
            }
        },
        .strong => |s| {
            try writer.print("Strong ('{c}')\n", .{s.marker});
            var buf: [256]u8 = undefined;
            const new_prefix = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, child_prefix_ext }) catch prefix;
            for (s.children.items, 0..) |child, j| {
                const last = j == s.children.items.len - 1;
                try printInline(writer, child, new_prefix, last);
            }
        },
        .code_span => |cs| {
            try writer.print("CodeSpan \"{s}\"\n", .{cs.content});
        },
        .link => |lnk| {
            try writer.print("Link url=\"{s}\"\n", .{lnk.destination.url});
            var buf: [256]u8 = undefined;
            const new_prefix = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, child_prefix_ext }) catch prefix;
            for (lnk.children.items, 0..) |child, j| {
                const last = j == lnk.children.items.len - 1;
                try printInline(writer, child, new_prefix, last);
            }
        },
        .image => |img| {
            try writer.print("Image alt=\"{s}\" url=\"{s}\"\n", .{ img.alt_text, img.destination.url });
        },
        .autolink => |al| {
            try writer.print("Autolink \"{s}\"\n", .{al.url});
        },
        .footnote_reference => |fr| {
            try writer.print("FootnoteRef [{s}]\n", .{fr.label});
        },
        .hard_break => {
            try writer.writeAll("HardBreak\n");
        },
        .soft_break => {
            try writer.writeAll("SoftBreak\n");
        },
        .html_in_line => |hi| {
            try writer.print("HtmlInline \"{s}\"\n", .{hi.content});
        },
    }
}
