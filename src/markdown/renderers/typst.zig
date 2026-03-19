//! Typst renderer for the Markdown AST — CommonMark + GFM.
//!
//! Serialises an `AST.Document` into valid Typst markup for PDF generation.
//! The document style is inspired by the Eisvogel LaTeX/Pandoc template,
//! providing a polished, professional layout with:
//!
//!   - Optional title page with coloured background
//!   - Configurable header and footer
//!   - Source Sans Pro body / Source Code Pro mono font stack
//!   - Styled blockquotes (left-border, grey text)
//!   - Syntax-annotated fenced code blocks
//!   - GFM extensions: tables, strikethrough, task-list checkboxes
//!   - Footnote expansion (definitions inlined at reference sites)
//!
//! Two entry points are provided:
//!
//!   * `render(allocator, doc)`                — body markup only; no
//!     preamble; valid as a standalone Typst file with default styling.
//!
//!   * `renderDocument(allocator, doc, opts)`  — full document with the
//!     Eisvogel-inspired preamble derived from `DocumentOptions`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const AST = @import("../ast.zig");

// ── Document options ──────────────────────────────────────────────────────────

/// Options for full Typst document generation, mirroring the Eisvogel
/// LaTeX template's YAML frontmatter variables.
pub const DocumentOptions = struct {
    // ── Document identity ─────────────────────────────────────────────────────
    title: ?[]const u8 = null,
    subtitle: ?[]const u8 = null,
    /// Single author string or the first element of an author list.
    author: ?[]const u8 = null,
    date: ?[]const u8 = null,

    // ── Layout ────────────────────────────────────────────────────────────────
    /// ISO paper size keyword understood by Typst (e.g. `"a4"`, `"us-letter"`).
    paper: []const u8 = "a4",
    lang: []const u8 = "en",
    fontsize: []const u8 = "11pt",

    // ── Title page ────────────────────────────────────────────────────────────
    titlepage: bool = false,
    /// Six-digit hex colour for the title-page background (no `#` prefix).
    titlepage_color: []const u8 = "1E3A5F",
    /// Six-digit hex colour for title-page text.
    titlepage_text_color: []const u8 = "FFFFFF",
    /// Six-digit hex colour for the horizontal rule on the title page.
    titlepage_rule_color: []const u8 = "AAAAAA",
    /// Height of the title-page rule in points.
    titlepage_rule_height: u32 = 4,

    // ── Header / footer ───────────────────────────────────────────────────────
    disable_header_and_footer: bool = false,
    header_left: ?[]const u8 = null,
    header_center: ?[]const u8 = null,
    /// Defaults to the document date when null.
    header_right: ?[]const u8 = null,
    /// Defaults to the author when null.
    footer_left: ?[]const u8 = null,
    footer_center: ?[]const u8 = null,
    /// Defaults to the page number when null.
    footer_right: ?[]const u8 = null,

    // ── Table of contents ─────────────────────────────────────────────────────
    toc: bool = false,
    toc_title: []const u8 = "Contents",
    toc_depth: u8 = 3,

    // ── Section numbering ─────────────────────────────────────────────────────
    numbersections: bool = false,

    // ── Links ─────────────────────────────────────────────────────────────────
    colorlinks: bool = true,
    /// Six-digit hex colour for hyperlinks.
    linkcolor: []const u8 = "A50000",
    /// Six-digit hex colour for URLs.
    urlcolor: []const u8 = "4077C0",
};

// ── Typst escape helper ───────────────────────────────────────────────────────

/// Write `s` with Typst markup special characters escaped.
///
/// In Typst's text/markup mode the following characters have syntactic meaning
/// and must be prefixed with a backslash to appear literally:
/// `\`, `*`, `_`, `` ` ``, `#`, `$`, `@`, `<`, `[`, `]`, `~`
fn writeEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '*'  => try writer.writeAll("\\*"),
            '_'  => try writer.writeAll("\\_"),
            '`'  => try writer.writeAll("\\`"),
            '#'  => try writer.writeAll("\\#"),
            '$'  => try writer.writeAll("\\$"),
            '@'  => try writer.writeAll("\\@"),
            '<'  => try writer.writeAll("\\<"),
            '['  => try writer.writeAll("\\["),
            ']'  => try writer.writeAll("\\]"),
            '~'  => try writer.writeAll("\\~"),
            else => try writer.writeByte(c),
        }
    }
}

/// Write `s` inside a Typst string literal (double-quoted).
/// Only `"` and `\` need escaping in this context.
fn writeStringLiteral(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"'  => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            else => try writer.writeByte(c),
        }
    }
}

// ── Render context ────────────────────────────────────────────────────────────

/// Shared context threaded through recursive rendering functions.
/// Holds the pre-collected footnote definition map so that
/// `footnote_reference` inlines can be expanded in-place.
const Ctx = struct {
    /// label → definition node (borrowed references; lifetime == the AST).
    footnotes: std.StringHashMap(*const AST.FootnoteDefinition),

    fn init(allocator: Allocator) Ctx {
        return .{ .footnotes = std.StringHashMap(*const AST.FootnoteDefinition).init(allocator) };
    }

    fn deinit(self: *Ctx) void {
        self.footnotes.deinit();
    }
};

// ── Inline renderer ───────────────────────────────────────────────────────────

fn renderInline(writer: *std.Io.Writer, item: AST.Inline, ctx: *const Ctx) anyerror!void {
    switch (item) {
        .text => |t| try writeEscaped(writer, t.content),

        // Soft breaks collapse to a single space so the paragraph flows.
        .soft_break => try writer.writeByte(' '),

        // Hard breaks use Typst's backslash-newline escape.
        .hard_break => try writer.writeAll("\\\n"),

        .code_span => |cs| {
            try writer.writeByte('`');
            try writer.writeAll(cs.content);
            try writer.writeByte('`');
        },

        .emphasis => |e| {
            try writer.writeByte('_');
            for (e.children.items) |child| try renderInline(writer, child, ctx);
            try writer.writeByte('_');
        },

        .strong => |s| {
            try writer.writeByte('*');
            for (s.children.items) |child| try renderInline(writer, child, ctx);
            try writer.writeByte('*');
        },

        .strikethrough => |s| {
            try writer.writeAll("#strike[");
            for (s.children.items) |child| try renderInline(writer, child, ctx);
            try writer.writeByte(']');
        },

        .link => |l| {
            try writer.writeAll("#link(\"");
            try writeStringLiteral(writer, l.destination.url);
            try writer.writeAll("\")[");
            for (l.children.items) |child| try renderInline(writer, child, ctx);
            try writer.writeByte(']');
        },

        .image => |img| {
            // Typst images are block-level, but an image inside a paragraph
            // will appear inline via `#image(...)`.  Wrap in `#figure` only
            // when there is a caption to show.
            const has_caption = (img.destination.title != null and img.destination.title.?.len > 0) or img.alt_text.len > 0;
            if (has_caption) {
                try writer.writeAll("#figure(image(\"");
                try writeStringLiteral(writer, img.destination.url);
                try writer.writeAll("\"), caption: [");
                if (img.destination.title) |t| {
                    try writeEscaped(writer, t);
                } else {
                    try writeEscaped(writer, img.alt_text);
                }
                try writer.writeAll("])");
            } else {
                try writer.writeAll("#image(\"");
                try writeStringLiteral(writer, img.destination.url);
                try writer.writeAll("\")");
            }
        },

        .autolink => |al| {
            try writer.writeAll("#link(\"");
            if (al.is_email) try writer.writeAll("mailto:");
            if (al.is_gfm_www) try writer.writeAll("http://");
            try writeStringLiteral(writer, al.url);
            try writer.writeAll("\")[");
            try writeEscaped(writer, al.url);
            try writer.writeByte(']');
        },

        .footnote_reference => |fr| {
            if (ctx.footnotes.get(fr.label)) |def| {
                // Expand the footnote definition inline as a Typst footnote.
                try writer.writeAll("#footnote[");
                for (def.children.items) |child| {
                    try renderBlockInline(writer, child, ctx);
                }
                try writer.writeByte(']');
            } else {
                // Definition not found — emit a visible placeholder.
                try writer.writeAll("#footnote[");
                try writeEscaped(writer, fr.label);
                try writer.writeByte(']');
            }
        },

        // Inline HTML has no Typst equivalent — silently omit.
        .html_in_line => {},
    }
}

// ── Block renderer ────────────────────────────────────────────────────────────

/// Render a block *without* a trailing blank line — used when a block appears
/// inside another context (blockquote body, footnote body, etc.).
fn renderBlockInline(writer: *std.Io.Writer, block: AST.Block, ctx: *const Ctx) anyerror!void {
    switch (block) {
        .paragraph => |p| {
            for (p.children.items) |item| try renderInline(writer, item, ctx);
        },
        // Delegate everything else to the full renderer (it adds a blank line
        // at the end, which is acceptable inside a footnote / blockquote).
        else => try renderBlock(writer, block, ctx),
    }
}

/// Render a single block element to `writer`.
/// All block renderers append a trailing `\n` (and most add a blank line
/// for paragraph spacing).
fn renderBlock(writer: *std.Io.Writer, block: AST.Block, ctx: *const Ctx) anyerror!void {
    switch (block) {
        // ── Headings ─────────────────────────────────────────────────────────
        .heading => |h| {
            var i: u8 = 0;
            while (i < h.level) : (i += 1) try writer.writeByte('=');
            try writer.writeByte(' ');
            for (h.children.items) |item| try renderInline(writer, item, ctx);
            try writer.writeByte('\n');
        },

        // ── Paragraph ────────────────────────────────────────────────────────
        .paragraph => |p| {
            for (p.children.items) |item| try renderInline(writer, item, ctx);
            try writer.writeAll("\n\n");
        },

        // ── Thematic break ───────────────────────────────────────────────────
        .thematic_break => {
            try writer.writeAll("#line(length: 100%, stroke: rgb(\"#999999\"))\n\n");
        },

        // ── Code blocks ──────────────────────────────────────────────────────
        .code_block => |cb| {
            try writer.writeAll("```\n");
            try writer.writeAll(cb.content);
            if (cb.content.len == 0 or cb.content[cb.content.len - 1] != '\n')
                try writer.writeByte('\n');
            try writer.writeAll("```\n\n");
        },

        .fenced_code_block => |fcb| {
            try writer.writeAll("```");
            if (fcb.language) |lang| try writer.writeAll(lang);
            try writer.writeByte('\n');
            if (fcb.content.len > 0) {
                try writer.writeAll(fcb.content);
                if (fcb.content[fcb.content.len - 1] != '\n') try writer.writeByte('\n');
            }
            try writer.writeAll("```\n\n");
        },

        // ── Blockquote ───────────────────────────────────────────────────────
        // Render as a left-bordered block with grey text, matching the
        // Eisvogel `mdframed`-based blockquote style.
        .blockquote => |bq| {
            try writer.writeAll(
                "#block(\n" ++
                "  inset: (left: 12pt, top: 4pt, bottom: 4pt),\n" ++
                "  stroke: (left: (thickness: 3pt, paint: rgb(\"#DDDDDD\"))),\n" ++
                "  text(fill: rgb(\"#777777\"))[\n",
            );
            for (bq.children.items) |child| {
                try renderBlockInline(writer, child, ctx);
                try writer.writeByte('\n');
            }
            try writer.writeAll("])\n\n");
        },

        // ── Lists ─────────────────────────────────────────────────────────────
        .list => |lst| try renderList(writer, lst, ctx, 0),

        // ── Tables ───────────────────────────────────────────────────────────
        .table => |tbl| try renderTable(writer, tbl, ctx),

        // ── Footnote definitions ─────────────────────────────────────────────
        // Definitions are pre-collected and expanded at the reference site;
        // skip them during the main document pass.
        .footnote_definition => {},

        // ── Raw HTML ─────────────────────────────────────────────────────────
        // HTML blocks have no Typst equivalent — silently omit.
        .html_block => {},
    }
}

// ── List rendering ────────────────────────────────────────────────────────────

/// Render a list (and any nested lists) at the given `indent` level.
/// `indent == 0` means top-level; each level adds two spaces of indentation.
fn renderList(writer: *std.Io.Writer, lst: AST.List, ctx: *const Ctx, indent: usize) anyerror!void {
    const marker: []const u8 = if (lst.type == .ordered) "+" else "-";

    for (lst.items.items) |item| {
        // ── Indent ──────────────────────────────────────────────────────────
        var k: usize = 0;
        while (k < indent * 2) : (k += 1) try writer.writeByte(' ');

        // ── Bullet / number marker ───────────────────────────────────────────
        try writer.writeAll(marker);
        try writer.writeByte(' ');

        // ── GFM task-list checkbox ────────────────────────────────────────────
        if (item.task_list_checked) |checked| {
            if (checked) {
                try writer.writeAll("[x] ");
            } else {
                try writer.writeAll("[ ] ");
            }
        }

        // ── Item children ────────────────────────────────────────────────────
        // The first child of a list item is almost always a paragraph whose
        // text should appear on the same line as the bullet.  Subsequent
        // children (more paragraphs in a loose list, sub-lists, code blocks,
        // etc.) begin on a new line and are indented one level deeper.
        var first = true;
        for (item.children.items) |child| {
            switch (child) {
                .paragraph => |p| {
                    if (first) {
                        // Inline with the bullet marker.
                        for (p.children.items) |inl| try renderInline(writer, inl, ctx);
                        try writer.writeByte('\n');
                        if (!lst.tight) try writer.writeByte('\n');
                    } else {
                        // Continuation paragraph in a loose list item.
                        k = 0;
                        while (k < (indent + 1) * 2) : (k += 1) try writer.writeByte(' ');
                        for (p.children.items) |inl| try renderInline(writer, inl, ctx);
                        try writer.writeByte('\n');
                        if (!lst.tight) try writer.writeByte('\n');
                    }
                },
                .list => |sub| {
                    // Sub-list: start on a new line if this is the first child
                    // (i.e. the item has no text of its own before the sub-list).
                    if (first) try writer.writeByte('\n');
                    try renderList(writer, sub, ctx, indent + 1);
                },
                else => {
                    // Other block elements (code block, blockquote, …).
                    if (first) try writer.writeByte('\n');
                    // Indent and delegate to the generic block renderer.
                    // Note: the generic renderer currently does not honour
                    // an indent level — an improvement for the future.
                    try renderBlock(writer, child, ctx);
                },
            }
            first = false;
        }
    }

    // Blank line after the list only at the top level so sibling blocks are
    // visually separated without double-spacing nested lists.
    if (indent == 0) try writer.writeByte('\n');
}

// ── Table rendering ───────────────────────────────────────────────────────────

fn renderTable(writer: *std.Io.Writer, tbl: AST.Table, ctx: *const Ctx) anyerror!void {
    const ncols = tbl.alignments.items.len;

    try writer.writeAll("#table(\n");

    // Column count.
    try writer.print("  columns: {d},\n", .{ncols});

    // Per-column alignment.
    try writer.writeAll("  align: (");
    for (tbl.alignments.items, 0..) |col_align, i| {
        if (i > 0) try writer.writeAll(", ");
        switch (col_align) {
            .none   => try writer.writeAll("auto"),
            .left   => try writer.writeAll("left"),
            .center => try writer.writeAll("center"),
            .right  => try writer.writeAll("right"),
        }
    }
    try writer.writeAll("),\n");

    // Table rule colour (matches Eisvogel's `#999999`).
    try writer.writeAll("  stroke: rgb(\"#999999\"),\n");

    // Header row — bold text, wrapped in `table.header(…)`.
    try writer.writeAll("  table.header(\n");
    for (tbl.header.cells.items) |cell| {
        try writer.writeAll("    [*");
        for (cell.children.items) |inl| try renderInline(writer, inl, ctx);
        try writer.writeAll("*],\n");
    }
    // Pad missing header cells so the column count is correct.
    if (tbl.header.cells.items.len < ncols) {
        var pad = tbl.header.cells.items.len;
        while (pad < ncols) : (pad += 1) try writer.writeAll("    [],\n");
    }
    try writer.writeAll("  ),\n");

    // Body rows.
    for (tbl.body.items) |row| {
        for (row.cells.items) |cell| {
            try writer.writeAll("  [");
            for (cell.children.items) |inl| try renderInline(writer, inl, ctx);
            try writer.writeAll("],\n");
        }
        // Pad missing cells.
        if (row.cells.items.len < ncols) {
            var pad = row.cells.items.len;
            while (pad < ncols) : (pad += 1) try writer.writeAll("  [],\n");
        }
    }

    try writer.writeAll(")\n\n");
}

// ── Preamble ──────────────────────────────────────────────────────────────────

/// Write the Eisvogel-inspired Typst preamble (all `#set` / `#show` rules
/// and the title page) to `writer` according to `opts`.
fn writePreamble(writer: anytype, opts: DocumentOptions) !void {
    // ── Document metadata ────────────────────────────────────────────────────
    try writer.writeAll("#set document(\n");
    if (opts.title) |t| {
        try writer.writeAll("  title: \"");
        try writeStringLiteral(writer, t);
        try writer.writeAll("\",\n");
    }
    if (opts.author) |a| {
        try writer.writeAll("  author: \"");
        try writeStringLiteral(writer, a);
        try writer.writeAll("\",\n");
    }
    try writer.writeAll(")\n\n");

    // ── Page layout ──────────────────────────────────────────────────────────
    try writer.writeAll("#set page(\n");
    try writer.print("  paper: \"{s}\",\n", .{opts.paper});
    try writer.writeAll("  margin: (x: 2.5cm, y: 2.5cm),\n");

    if (!opts.disable_header_and_footer) {
        // Header
        try writer.writeAll("  header: [\n");
        try writer.writeAll("    #set text(size: 9pt, fill: rgb(\"#777777\"))\n");
        try writer.writeAll("    #grid(\n");
        try writer.writeAll("      columns: (1fr, 1fr, 1fr),\n");
        try writer.writeAll("      align: (left, center, right),\n");

        // Left header
        try writer.writeByte('[');
        if (opts.header_left) |hl| {
            try writeEscaped(writer, hl);
        } else if (opts.title) |t| {
            try writeEscaped(writer, t);
        }
        try writer.writeAll("],\n");

        // Center header
        try writer.writeByte('[');
        if (opts.header_center) |hc| try writeEscaped(writer, hc);
        try writer.writeAll("],\n");

        // Right header
        try writer.writeByte('[');
        if (opts.header_right) |hr| {
            try writeEscaped(writer, hr);
        } else if (opts.date) |d| {
            try writeEscaped(writer, d);
        }
        try writer.writeAll("],\n");

        try writer.writeAll("    )\n  ],\n");

        // Footer
        try writer.writeAll("  footer: [\n");
        try writer.writeAll("    #set text(size: 9pt, fill: rgb(\"#777777\"))\n");
        try writer.writeAll("    #grid(\n");
        try writer.writeAll("      columns: (1fr, 1fr, 1fr),\n");
        try writer.writeAll("      align: (left, center, right),\n");

        // Left footer
        try writer.writeByte('[');
        if (opts.footer_left) |fl| {
            try writeEscaped(writer, fl);
        } else if (opts.author) |a| {
            try writeEscaped(writer, a);
        }
        try writer.writeAll("],\n");

        // Center footer
        try writer.writeByte('[');
        if (opts.footer_center) |fc| try writeEscaped(writer, fc);
        try writer.writeAll("],\n");

        // Right footer (page number by default)
        try writer.writeByte('[');
        if (opts.footer_right) |fr| {
            try writeEscaped(writer, fr);
        } else {
            try writer.writeAll("#context counter(page).display(\"1\")");
        }
        try writer.writeAll("],\n");

        try writer.writeAll("    )\n  ],\n");
    }

    try writer.writeAll(")\n\n");

    // ── Text / font settings ─────────────────────────────────────────────────
    try writer.print(
        "#set text(\n" ++
        "  font: (\"Source Sans Pro\", \"Helvetica\", \"Arial\"),\n" ++
        "  size: {s},\n" ++
        "  lang: \"{s}\",\n" ++
        ")\n\n",
        .{ opts.fontsize, opts.lang },
    );

    // Monospace font for raw / code.
    try writer.writeAll(
        "#show raw: set text(font: (\"Source Code Pro\", \"Courier New\", \"monospace\"))\n\n",
    );

    // ── Code-block styling ───────────────────────────────────────────────────
    // Light grey background, slight rounding — mirrors Eisvogel's listings style.
    try writer.writeAll(
        "#show raw.where(block: true): it => block(\n" ++
        "  fill: rgb(\"#F7F7F7\"),\n" ++
        "  inset: 10pt,\n" ++
        "  radius: 4pt,\n" ++
        "  width: 100%,\n" ++
        "  stroke: 0.5pt + rgb(\"#DDDDDD\"),\n" ++
        "  it,\n" ++
        ")\n\n",
    );

    // ── Heading styling ──────────────────────────────────────────────────────
    // Dark charcoal headings, matching Eisvogel's `#282828`.
    try writer.writeAll(
        "#show heading: it => {\n" ++
        "  set text(fill: rgb(\"#282828\"))\n" ++
        "  it\n" ++
        "}\n\n",
    );

    // ── Section numbering ────────────────────────────────────────────────────
    if (opts.numbersections) {
        try writer.writeAll("#set heading(numbering: \"1.\")\n\n");
    }

    // ── Link colours ─────────────────────────────────────────────────────────
    if (opts.colorlinks) {
        try writer.print(
            "#show link: set text(fill: rgb(\"#{s}\"))\n\n",
            .{opts.linkcolor},
        );
    }

    // ── Figure / caption styling ─────────────────────────────────────────────
    try writer.writeAll(
        "#show figure.caption: it => {\n" ++
        "  set text(fill: rgb(\"#777777\"), size: 9pt)\n" ++
        "  it\n" ++
        "}\n\n",
    );

    // ── Title page ───────────────────────────────────────────────────────────
    if (opts.titlepage) {
        try writer.writeAll("// ── Title page ─────────────────────────────────────────────────────────\n");
        try writer.writeAll("#page(\n");
        try writer.writeAll("  margin: (x: 0cm, y: 0cm),\n");
        try writer.writeAll("  header: none,\n");
        try writer.writeAll("  footer: none,\n");
        try writer.writeAll(")[\n");

        // Full-page coloured background.
        try writer.print(
            "  #rect(width: 100%, height: 100%, fill: rgb(\"#{s}\"))[\n",
            .{opts.titlepage_color},
        );

        // Title text block.
        try writer.print(
            "    #set text(fill: rgb(\"#{s}\"))\n",
            .{opts.titlepage_text_color},
        );
        try writer.writeAll("    #align(horizon)[\n");
        try writer.writeAll("      #pad(left: 2.5cm, right: 2.5cm)[\n");

        if (opts.title) |t| {
            try writer.writeAll("        #text(size: 36pt, weight: \"bold\")[");
            try writeEscaped(writer, t);
            try writer.writeAll("]\n\n");
        }

        if (opts.subtitle) |s| {
            try writer.writeAll("        #text(size: 24pt)[");
            try writeEscaped(writer, s);
            try writer.writeAll("]\n\n");
        }

        // Coloured rule.
        try writer.print(
            "        #line(length: 100%, stroke: {d}pt + rgb(\"#{s}\"))\n\n",
            .{ opts.titlepage_rule_height, opts.titlepage_rule_color },
        );

        if (opts.author) |a| {
            try writer.writeAll("        #text(size: 18pt)[");
            try writeEscaped(writer, a);
            try writer.writeAll("]\n\n");
        }

        if (opts.date) |d| {
            try writer.writeAll("        #text(size: 14pt)[");
            try writeEscaped(writer, d);
            try writer.writeAll("]\n");
        }

        try writer.writeAll("      ]\n    ]\n  ]\n]\n\n");
    }

    // ── Table of contents ────────────────────────────────────────────────────
    if (opts.toc) {
        try writer.print(
            "#outline(\n" ++
            "  title: \"{s}\",\n" ++
            "  depth: {d},\n" ++
            ")\n\n",
            .{ opts.toc_title, opts.toc_depth },
        );
    }
}

// ── Footnote pre-pass ─────────────────────────────────────────────────────────

/// Scan `doc.children` and populate `ctx.footnotes` with all
/// `footnote_definition` nodes, keyed by their label.
fn collectFootnotes(doc: AST.Document, ctx: *Ctx) !void {
    for (doc.children.items) |*child| {
        if (child.* == .footnote_definition) {
            try ctx.footnotes.put(child.footnote_definition.label, &child.footnote_definition);
        }
    }
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Render `doc` to an allocator-owned Typst byte slice (body only; no preamble).
///
/// The output is valid as a standalone Typst source file — Typst's default
/// styles will be applied.  For the full Eisvogel-inspired layout use
/// `renderDocument`.
///
/// The caller owns the returned memory and must free it when done.
pub fn render(allocator: Allocator, doc: AST.Document) ![]u8 {
    var ctx = Ctx.init(allocator);
    defer ctx.deinit();
    try collectFootnotes(doc, &ctx);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    for (doc.children.items) |child| {
        // Footnote definitions are expanded at the reference site.
        if (child == .footnote_definition) continue;
        try renderBlock(&aw.writer, child, &ctx);
    }

    return aw.toOwnedSlice();
}

/// Render `doc` as a complete Typst document with an Eisvogel-inspired
/// preamble derived from `opts`.
///
/// The caller owns the returned memory and must free it when done.
pub fn renderDocument(allocator: Allocator, doc: AST.Document, opts: DocumentOptions) ![]u8 {
    var ctx = Ctx.init(allocator);
    defer ctx.deinit();
    try collectFootnotes(doc, &ctx);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try writePreamble(&aw.writer, opts);

    for (doc.children.items) |child| {
        if (child == .footnote_definition) continue;
        try renderBlock(&aw.writer, child, &ctx);
    }

    return aw.toOwnedSlice();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const tst = std.testing;
const Parser = @import("../parser.zig");

fn ok(src: []const u8, expected: []const u8) !void {
    const allocator = tst.allocator;
    var parser = Parser.init();
    defer parser.deinit(allocator);
    var res = try parser.parseMarkdown(allocator, src);
    defer res.deinit(allocator);
    const out = try render(allocator, res);
    defer allocator.free(out);
    try tst.expectEqualStrings(expected, out);
}

test "heading levels" {
    try ok("# H1", "= H1\n");
    try ok("## H2", "== H2\n");
    try ok("### H3", "=== H3\n");
    try ok("#### H4", "==== H4\n");
}

test "paragraph" {
    try ok("Hello world", "Hello world\n\n");
}

test "bold and italic" {
    try ok("**bold**", "*bold*\n\n");
    try ok("*italic*", "_italic_\n\n");
    try ok("_italic_", "_italic_\n\n");
    try ok("__bold__", "*bold*\n\n");
}

test "strikethrough" {
    try ok("~~del~~", "#strike[del]\n\n");
}

test "code span" {
    try ok("`code`", "`code`\n\n");
}

test "fenced code block no lang" {
    try ok("```\nhello\n```", "```\nhello\n```\n\n");
}

test "fenced code block with lang" {
    try ok("```zig\nconst x = 1;\n```", "```zig\nconst x = 1;\n```\n\n");
}

test "thematic break" {
    try ok("---", "#line(length: 100%, stroke: rgb(\"#999999\"))\n\n");
}

test "blockquote" {
    try ok("> a quote", "#block(\n  inset: (left: 12pt, top: 4pt, bottom: 4pt),\n  stroke: (left: (thickness: 3pt, paint: rgb(\"#DDDDDD\"))),\n  text(fill: rgb(\"#777777\"))[\na quote\n])\n\n");
}

test "unordered list tight" {
    try ok("- a\n- b", "- a\n- b\n\n");
}

test "ordered list tight" {
    try ok("1. first\n2. second", "+ first\n+ second\n\n");
}

test "link" {
    try ok("[text](https://example.com)", "#link(\"https://example.com\")[text]\n\n");
}

test "autolink" {
    try ok("<https://example.com>", "#link(\"https://example.com\")[https://example.com]\n\n");
}

test "special char escaping" {
    try ok("a # b", "a \\# b\n\n");
    try ok("a * b", "a \\* b\n\n");
    try ok("a _ b", "a \\_ b\n\n");
    try ok("a $ b", "a \\$ b\n\n");
}

test "renderDocument smoke test" {
    const allocator = tst.allocator;
    var parser = Parser.init();
    defer parser.deinit(allocator);
    var res = try parser.parseMarkdown(allocator, "# Hello\n\nWorld.");
    defer res.deinit(allocator);
    const out = try renderDocument(allocator, res, .{
        .title = "Test Doc",
        .author = "Alice",
        .date = "2026-03-19",
        .titlepage = true,
        .toc = false,
    });
    defer allocator.free(out);
    // Verify key preamble sections are present.
    try tst.expect(std.mem.indexOf(u8, out, "#set document(") != null);
    try tst.expect(std.mem.indexOf(u8, out, "#set page(") != null);
    try tst.expect(std.mem.indexOf(u8, out, "#set text(") != null);
    try tst.expect(std.mem.indexOf(u8, out, "Source Sans Pro") != null);
    try tst.expect(std.mem.indexOf(u8, out, "= Hello") != null);
    try tst.expect(std.mem.indexOf(u8, out, "World.") != null);
}
