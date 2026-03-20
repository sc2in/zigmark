const std = @import("std");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .tokenizer, .level = .warn },
        .{ .scope = .parser, .level = .warn },
    },
};

const clap = @import("clap");
const zigmark = @import("zigmark");
const AST = zigmark.AST;
const version = zigmark.version;

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const alloc = gpa;

    // ── CLI definition ───────────────────────────────────────────────────────
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Display this help and exit.
        \\-v, --version             Print version and exit.
        \\-f, --format <str>        Output format: "html" (default), "ast", "ai", "terminal",
        \\                          "frontmatter", "markdown", "normalize", or "typst".
        \\-o, --output <str>        Write output to FILE instead of stdout.
        \\-s, --set <str>...        Set a frontmatter field (KEY=VALUE). Repeatable.
        \\                          Applies to: markdown, normalize, frontmatter formats.
        \\-d, --delete <str>...     Delete a frontmatter field (dot-path). Repeatable.
        \\                          Applies to: markdown, normalize, frontmatter formats.
        \\-e, --set-block <str>...  Edit a body block (SELECTOR=CONTENT). Selectors: block[N],
        \\                          heading[N], paragraph[N], table[N]. The first block parsed
        \\                          from CONTENT replaces the selected block. Repeatable.
        \\                          Applies to: normalize format.
        \\--section-start <str>     ) Replace document body between two HTML comment markers
        \\--section-end <str>       ) with Markdown read from stdin. FILE arg required.
        \\                            Applies to: normalize format.
        \\<str>                     Input markdown file (reads stdin if omitted).
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

    // ── Early validation ─────────────────────────────────────────────────────
    {
        const has_start = res.args.@"section-start" != null;
        const has_end = res.args.@"section-end" != null;
        if (has_start != has_end) {
            std.debug.print("error: --section-start and --section-end must be used together\n", .{});
            return error.InvalidArgument;
        }
        if (has_start and res.positionals[0] == null) {
            std.debug.print("error: --section-start/--section-end requires a FILE positional argument (stdin is used for replacement content)\n", .{});
            return error.InvalidArgument;
        }
    }

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
            \\Formats:
            \\  html         CommonMark-compliant HTML (default)
            \\  ast          Human-readable AST tree diagram
            \\  ai           Token-efficient AI representation
            \\  terminal     ANSI-styled terminal output
            \\  frontmatter  Print parsed frontmatter as JSON
            \\  markdown     Passthrough: re-serialize frontmatter in its original
            \\               format and pass the body through verbatim. Useful for
            \\               frontmatter editing without touching the body.
            \\  normalize    Reconstruct normalized Markdown from the AST. Converts
            \\               headings to ATX, links to inline, code blocks to fenced.
            \\               Supports --set-block and --section-start/--section-end
            \\               for body mutation.
            \\  typst        Typst markup for PDF generation. Reads YAML frontmatter
            \\               fields (title, author, date, titlepage, toc, …) to produce
            \\               a full Eisvogel-inspired document layout.
            \\
            \\Body mutation (normalize format only):
            \\  --set-block heading[0]="# New Title"   Replace the first heading.
            \\  --set-block block[3]="paragraph text"  Replace block at absolute index 3.
            \\  --section-start bench-start \
            \\  --section-end   bench-end   \
            \\  < new-content.md FILE -o FILE          Replace content between
            \\                                         <!-- bench-start --> and
            \\                                         <!-- bench-end --> markers.
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

    // ── Output ───────────────────────────────────────────────────────────────
    const out_file = getOutputFile(res.args.output);
    defer closeOutput(res.args.output, out_file);
    var out_buf: [8192]u8 = undefined;
    var writer = out_file.writer(&out_buf);

    // ── Frontmatter passthrough ("markdown") ─────────────────────────────────
    // Parse frontmatter, apply --set/--delete, re-serialize in original format,
    // then pass the body through verbatim. Does NOT re-parse the body.
    if (std.mem.eql(u8, format, "markdown")) {
        const body_off = zigmark.Frontmatter.bodyOffset(input) orelse 0;
        const body = input[body_off..];

        if (body_off > 0) {
            var fm = zigmark.Frontmatter.initFromMarkdown(alloc, input) catch |err| {
                std.debug.print("error: failed to parse frontmatter: {}\n", .{err});
                return err;
            };
            defer fm.deinit();
            applyFrontmatterMods(&fm, res.args.set, res.args.delete);
            const fm_str = fm.serialize(alloc) catch |err| {
                std.debug.print("error: failed to serialize frontmatter: {}\n", .{err});
                return err;
            };
            defer alloc.free(fm_str);
            writer.interface.writeAll(fm_str) catch {};
            // Ensure one blank line between frontmatter and body
            if (body.len > 0 and body[0] != '\n') writer.interface.writeByte('\n') catch {};
        }
        writer.interface.writeAll(body) catch {};
        writer.interface.flush() catch {};
        return;
    }

    // ── Frontmatter JSON dump ("frontmatter") ────────────────────────────────
    if (std.mem.eql(u8, format, "frontmatter")) {
        var fm = zigmark.Frontmatter.initFromMarkdown(alloc, input) catch |err| switch (err) {
            error.InvalidFrontMatter => {
                writer.interface.writeAll("{}\n") catch {};
                writer.interface.flush() catch {};
                return;
            },
            else => {
                std.debug.print("error: failed to parse frontmatter: {}\n", .{err});
                return err;
            },
        };
        defer fm.deinit();
        applyFrontmatterMods(&fm, res.args.set, res.args.delete);
        const json_out = std.json.Stringify.valueAlloc(alloc, fm.root, .{ .whitespace = .indent_2 }) catch |err| {
            std.debug.print("error: failed to serialize frontmatter to JSON: {}\n", .{err});
            return err;
        };
        defer alloc.free(json_out);
        writer.interface.writeAll(json_out) catch {};
        writer.interface.writeAll("\n") catch {};
        writer.interface.flush() catch {};
        return;
    }

    // ── Parse body (strip frontmatter for body-only formats) ─────────────────
    const body_start = zigmark.Frontmatter.bodyOffset(input) orelse 0;
    const body_input = input[body_start..];

    var parser = zigmark.Parser.init();
    var doc = parser.parseMarkdown(alloc, body_input) catch |err| {
        std.debug.print("error: failed to parse markdown: {}\n", .{err});
        return err;
    };
    defer doc.deinit(alloc);

    // ── Normalize ("normalize") — full AST→Markdown reconstruction ───────────
    if (std.mem.eql(u8, format, "normalize")) {
        // Re-serialize frontmatter if present (with any mods)
        if (body_start > 0) {
            var fm = zigmark.Frontmatter.initFromMarkdown(alloc, input) catch null;
            if (fm) |*f| {
                defer f.deinit();
                applyFrontmatterMods(f, res.args.set, res.args.delete);
                const fm_str = f.serialize(alloc) catch null;
                if (fm_str) |s| {
                    defer alloc.free(s);
                    writer.interface.writeAll(s) catch {};
                    writer.interface.writeByte('\n') catch {};
                }
            }
        }

        // ── Body block mutations ──────────────────────────────────────────────

        // --set-block "heading[0]=# New Title"
        for (res.args.@"set-block") |arg| {
            applySetBlock(alloc, &doc, arg) catch |err| {
                std.debug.print("warning: --set-block '{s}': {}\n", .{ arg, err });
            };
        }

        // --section-start / --section-end  (reads replacement from stdin)
        if (res.args.@"section-start") |start_marker| {
            const end_marker = res.args.@"section-end".?;
            const stdin = std.fs.File.stdin();
            const replacement_src = stdin.readToEndAlloc(alloc, std.math.maxInt(usize)) catch |err| {
                std.debug.print("error: failed to read replacement content from stdin: {}\n", .{err});
                return err;
            };
            defer alloc.free(replacement_src);
            applyReplaceSection(alloc, &doc, start_marker, end_marker, replacement_src) catch |err| {
                std.debug.print("error: --section-start/--section-end: {}\n", .{err});
                return err;
            };
        }

        zigmark.MarkdownRenderer.renderToWriter(alloc, &writer.interface, doc) catch |err| {
            std.debug.print("error: failed to render normalized markdown: {}\n", .{err});
            return err;
        };
        writer.interface.flush() catch {};
        return;
    }

    // ── HTML ─────────────────────────────────────────────────────────────────
    if (std.mem.eql(u8, format, "html")) {
        zigmark.HTMLRenderer.renderToWriter(alloc, &writer.interface, doc) catch |err| {
            std.debug.print("error: failed to render HTML: {}\n", .{err});
            return err;
        };
        writer.interface.flush() catch {};
    } else if (std.mem.eql(u8, format, "ast")) {
        zigmark.ASTRenderer.renderToWriter(alloc, &writer.interface, doc) catch |err| {
            std.debug.print("error: failed to render AST: {}\n", .{err});
            return err;
        };
        writer.interface.flush() catch {};
    } else if (std.mem.eql(u8, format, "ai")) {
        zigmark.AIRenderer.renderToWriter(alloc, &writer.interface, doc) catch |err| {
            std.debug.print("error: failed to render AI AST: {}\n", .{err});
            return err;
        };
        writer.interface.flush() catch {};
    } else if (std.mem.eql(u8, format, "terminal")) {
        zigmark.TerminalRenderer.renderToWriter(alloc, &writer.interface, doc) catch |err| {
            std.debug.print("error: failed to render terminal output: {}\n", .{err});
            return err;
        };
        writer.interface.flush() catch {};
    } else if (std.mem.eql(u8, format, "typst")) {
        // Build DocumentOptions from frontmatter (if present), then render.
        // `fm` must outlive `opts` since DocumentOptions borrows string slices.
        var fm_opt: ?zigmark.Frontmatter = if (body_start > 0)
            zigmark.Frontmatter.initFromMarkdown(alloc, input) catch null
        else
            null;
        defer if (fm_opt) |*f| f.deinit();
        const opts: zigmark.typst.DocumentOptions = if (fm_opt) |*f|
            frontmatterToTypstOpts(f)
        else
            .{};
        zigmark.typst.renderDocumentToWriter(alloc, &writer.interface, doc, opts) catch |err| {
            std.debug.print("error: failed to render Typst: {}\n", .{err});
            return err;
        };
        writer.interface.flush() catch {};
    } else {
        std.debug.print(
            "error: unknown format '{s}'. Use 'html', 'ast', 'ai', 'terminal', 'frontmatter', 'markdown', 'normalize', or 'typst'.\n",
            .{format},
        );
        return error.InvalidArgument;
    }
}

// ── Typst frontmatter helper ──────────────────────────────────────────────────

/// Coerce a `std.json.Value` to `bool`, handling both native `.bool` values
/// and string scalars (`"true"` / `"false"`) as produced by the YAML parser.
fn jsonAsBool(v: std.json.Value) ?bool {
    return switch (v) {
        .bool   => |b| b,
        .string => |s| if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "yes"))
            true
        else if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "no"))
            false
        else
            null,
        else => null,
    };
}

/// Map YAML/TOML/JSON frontmatter fields to `DocumentOptions`.
/// String slices borrow from the frontmatter's arena; the caller must ensure
/// `fm` outlives the returned `DocumentOptions`.
fn frontmatterToTypstOpts(fm: *const zigmark.Frontmatter) zigmark.typst.DocumentOptions {
    var opts: zigmark.typst.DocumentOptions = .{};

    if (fm.get("title"))    |v| if (v == .string) { opts.title    = v.string; };
    if (fm.get("subtitle")) |v| if (v == .string) { opts.subtitle = v.string; };
    if (fm.get("date"))     |v| if (v == .string) { opts.date     = v.string; };
    if (fm.get("lang"))     |v| if (v == .string) { opts.lang     = v.string; };
    if (fm.get("papersize"))|v| if (v == .string) { opts.paper    = v.string; };
    if (fm.get("fontsize")) |v| if (v == .string) { opts.fontsize = v.string; };

    // `author` may be a plain string or an array — use the first element.
    if (fm.get("author")) |v| switch (v) {
        .string => opts.author = v.string,
        .array  => if (v.array.items.len > 0 and v.array.items[0] == .string) {
            opts.author = v.array.items[0].string;
        },
        else => {},
    };

    // ── Title page ────────────────────────────────────────────────────────────
    if (fm.get("titlepage"))            |v| { if (jsonAsBool(v)) |b| opts.titlepage            = b; }
    if (fm.get("titlepage-color"))      |v| if (v == .string) { opts.titlepage_color      = v.string; };
    if (fm.get("titlepage-text-color")) |v| if (v == .string) { opts.titlepage_text_color = v.string; };
    if (fm.get("titlepage-rule-color")) |v| if (v == .string) { opts.titlepage_rule_color = v.string; };
    if (fm.get("titlepage-rule-height"))|v| if (v == .integer) { opts.titlepage_rule_height = @intCast(v.integer); };

    // ── TOC ───────────────────────────────────────────────────────────────────
    if (fm.get("toc"))       |v| { if (jsonAsBool(v)) |b| opts.toc       = b; }
    if (fm.get("toc-title")) |v| if (v == .string)  { opts.toc_title = v.string; };
    if (fm.get("toc-depth")) |v| if (v == .integer) { opts.toc_depth = @intCast(v.integer); };

    // ── Sections / links ──────────────────────────────────────────────────────
    if (fm.get("numbersections")) |v| { if (jsonAsBool(v)) |b| opts.numbersections = b; }
    if (fm.get("colorlinks"))     |v| { if (jsonAsBool(v)) |b| opts.colorlinks     = b; }
    if (fm.get("linkcolor"))      |v| if (v == .string) { opts.linkcolor = v.string; };
    if (fm.get("urlcolor"))       |v| if (v == .string) { opts.urlcolor  = v.string; };

    // ── Header / footer ───────────────────────────────────────────────────────
    if (fm.get("disable-header-and-footer")) |v| { if (jsonAsBool(v)) |b| opts.disable_header_and_footer = b; }
    if (fm.get("header-left"))   |v| if (v == .string) { opts.header_left   = v.string; };
    if (fm.get("header-center")) |v| if (v == .string) { opts.header_center = v.string; };
    if (fm.get("header-right"))  |v| if (v == .string) { opts.header_right  = v.string; };
    if (fm.get("footer-left"))   |v| if (v == .string) { opts.footer_left   = v.string; };
    if (fm.get("footer-center")) |v| if (v == .string) { opts.footer_center = v.string; };
    if (fm.get("footer-right"))  |v| if (v == .string) { opts.footer_right  = v.string; };

    return opts;
}

// ── Frontmatter modification helper ──────────────────────────────────────────

/// Apply `--set` and `--delete` flags to `fm`.  Errors from individual
/// operations are silently skipped so a bad flag does not abort the run.
fn applyFrontmatterMods(
    fm: *zigmark.Frontmatter,
    sets: []const []const u8,
    deletes: []const []const u8,
) void {
    for (sets) |arg| {
        const fa = zigmark.Frontmatter.parseFieldArg(arg) catch continue;
        fm.set(fa.path, fa.value) catch continue;
    }
    for (deletes) |key| _ = fm.delete(key);
}

// ── Body block mutation helpers ───────────────────────────────────────────────

/// Apply one `--set-block "selector=content"` argument to `doc`.
/// The first block parsed from `content` replaces the selected block.
fn applySetBlock(alloc: std.mem.Allocator, doc: *AST.Document, arg: []const u8) !void {
    const eq_pos = std.mem.indexOf(u8, arg, "=") orelse return error.MissingEquals;
    const selector = arg[0..eq_pos];
    const content = arg[eq_pos + 1 ..];

    const doc_idx = resolveBlockSelector(doc.*, selector) orelse return error.SelectorNotFound;
    const new_block = try parseFirstBlock(alloc, content);
    doc.edit().replaceBlock(alloc, doc_idx, new_block);
}

/// Resolve a selector like `"block[3]"` or `"heading[0]"` to an absolute
/// index into `doc.children`.  Returns `null` if out of range or not found.
fn resolveBlockSelector(doc: AST.Document, selector: []const u8) ?usize {
    const bracket = std.mem.indexOf(u8, selector, "[") orelse return null;
    const close_pos = std.mem.indexOf(u8, selector[bracket..], "]") orelse return null;
    const type_name = selector[0..bracket];
    const index_num = std.fmt.parseInt(usize, selector[bracket + 1 .. bracket + close_pos], 10) catch return null;

    if (std.mem.eql(u8, type_name, "block")) {
        return if (index_num < doc.children.items.len) index_num else null;
    }

    var counter: usize = 0;
    for (doc.children.items, 0..) |block, i| {
        if (std.mem.eql(u8, @tagName(std.meta.activeTag(block)), type_name)) {
            if (counter == index_num) return i;
            counter += 1;
        }
    }
    return null;
}

/// Parse `content` as Markdown and return (taking ownership of) the first
/// block.  The rest of the parsed document is deinit'd.
/// Returns `error.EmptyContent` if `content` parses to zero blocks.
fn parseFirstBlock(alloc: std.mem.Allocator, content: []const u8) !AST.Block {
    var parser = zigmark.Parser.init();
    var content_doc = try parser.parseMarkdown(alloc, content);

    if (content_doc.children.items.len == 0) {
        content_doc.deinit(alloc);
        return error.EmptyContent;
    }

    // Steal the first block: remove it from the list without freeing it,
    // then deinit the rest.
    const first_block = content_doc.children.items[0];
    const remaining = content_doc.children.items.len - 1;
    std.mem.copyForwards(AST.Block, content_doc.children.items[0..remaining], content_doc.children.items[1..]);
    content_doc.children.items.len = remaining;
    content_doc.deinit(alloc);

    return first_block;
}

/// Replace the body content between two HTML comment markers with blocks
/// parsed from `replacement_src`.  The marker blocks themselves are kept;
/// everything between them is removed and the new blocks are inserted there.
fn applyReplaceSection(
    alloc: std.mem.Allocator,
    doc: *AST.Document,
    start_marker: []const u8,
    end_marker: []const u8,
    replacement_src: []const u8,
) !void {
    const start_idx = findHtmlCommentBlock(doc.*, start_marker) orelse return error.StartMarkerNotFound;
    const end_idx = findHtmlCommentBlock(doc.*, end_marker) orelse return error.EndMarkerNotFound;
    if (start_idx >= end_idx) return error.InvalidMarkerOrder;

    // Parse replacement content.
    var rep_parser = zigmark.Parser.init();
    var rep_doc = try rep_parser.parseMarkdown(alloc, replacement_src);
    // We will steal rep_doc's blocks, so do NOT call rep_doc.deinit() normally.

    // Remove blocks between the markers (exclusive), highest index first so
    // that lower indices stay stable.
    if (end_idx > start_idx + 1) {
        var i: usize = end_idx - 1;
        while (i > start_idx) {
            doc.edit().removeBlock(alloc, i);
            i -= 1;
        }
    }
    // Now start_idx + 1 is where end_marker sits.  Insert new blocks there.
    const insert_pos = start_idx + 1;
    for (rep_doc.children.items, 0..) |block, j| {
        try doc.edit().insertBlock(alloc, insert_pos + j, block);
    }

    // Blocks are now owned by doc; just free the ArrayList backing array.
    rep_doc.children.items.len = 0;
    rep_doc.deinit(alloc);
}

/// Return the index of the first `html_block` in `doc.children` whose
/// content contains `marker`, or `null` if none is found.
fn findHtmlCommentBlock(doc: AST.Document, marker: []const u8) ?usize {
    for (doc.children.items, 0..) |block, i| {
        switch (block) {
            .html_block => |hb| {
                if (std.mem.indexOf(u8, hb.content, marker) != null) return i;
            },
            else => {},
        }
    }
    return null;
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
