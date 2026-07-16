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
        // Aligned prongs are intentional
        // zig fmt: off
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
        // zig fmt: on
    }
}

/// Write `s` inside a Typst string literal (double-quoted).
/// Only `"` and `\` need escaping in this context.
fn writeStringLiteral(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        // Aligned prongs are intentional
        // zig fmt: off
        switch (c) {
            '"'  => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            else => try writer.writeByte(c),
        }
        // zig fmt: on
    }
}

/// Write the `alt:` argument for a Typst `image(…)` call when the Markdown
/// alt text is non-empty (Typst embeds it as the PDF alt text for
/// accessibility / PDF-UA).  Emitted via `writeStringLiteral` so the value
/// cannot escape the string literal.
fn writeImageAlt(writer: anytype, alt_text: []const u8) !void {
    if (alt_text.len == 0) return;
    try writer.writeAll(", alt: \"");
    try writeStringLiteral(writer, alt_text);
    try writer.writeByte('"');
}

// ── Preamble field validation (Typst code-injection guards) ───────────────────
//
// Frontmatter-derived option fields flow into the Typst preamble. Typst runs at
// compile time and can read local files, so any untrusted value interpolated
// into Typst code — even inside a string literal, which can be closed with `"` —
// must be validated or escaped. String fields go through `writeStringLiteral`;
// the guards below cover the two fields emitted in non-string positions:
// colours (inside `rgb("#…")`) and the *unquoted* `fontsize` expression.

/// True if `s` is a valid hex colour body (3/4/6/8 hex digits, no `#`).
fn isHexColor(s: []const u8) bool {
    if (s.len != 3 and s.len != 4 and s.len != 6 and s.len != 8) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// Return `s` if it is a valid hex colour, otherwise `default`.
fn hexColorOr(s: []const u8, default: []const u8) []const u8 {
    return if (isHexColor(s)) s else default;
}

/// True if `s` is a bare Typst length literal: digits, an optional fractional
/// part, and a known unit. `fontsize` is emitted as an unquoted expression, so
/// it must be validated as a length token rather than string-escaped.
fn isTypstLength(s: []const u8) bool {
    var i: usize = 0;
    var saw_digit = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) saw_digit = true;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) saw_digit = true;
    }
    if (!saw_digit) return false;
    const unit = s[i..];
    const units = [_][]const u8{ "pt", "mm", "cm", "in", "em" };
    for (units) |u| if (std.mem.eql(u8, unit, u)) return true;
    return false;
}

/// Return `s` if it is a valid Typst length literal, otherwise `default`.
fn lengthOr(s: []const u8, default: []const u8) []const u8 {
    return if (isTypstLength(s)) s else default;
}

// ── Render context ────────────────────────────────────────────────────────────

/// Shared context threaded through recursive rendering functions.
/// Holds the pre-collected footnote definition map so that
/// `footnote_reference` inlines can be expanded in-place.
const Ctx = struct {
    /// label → definition node (borrowed references; lifetime == the AST).
    footnotes: std.StringHashMap(*const AST.FootnoteDefinition),
    allocator: Allocator,
    mermaid: ?*const fn (Allocator, []const u8) anyerror![]const u8 = null,

    fn init(allocator: Allocator) Ctx {
        return .{
            .footnotes = std.StringHashMap(*const AST.FootnoteDefinition).init(allocator),
            .allocator = allocator,
        };
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
            // Use Typst's `raw()` with a string literal so backticks in the
            // content cannot break out of raw mode into executable Typst markup
            // (Typst runs at compile time and can read local files).
            try writer.writeAll("#raw(\"");
            try writeStringLiteral(writer, cs.content);
            try writer.writeAll("\")");
        },

        .math => |m| {
            // TeX math rendered via mitex (https://typst.app/universe/package/mitex):
            // `#mi(…)` for inline math, `#mitex(…)` for display math.  The TeX
            // source goes inside a Typst string literal (same injection-safe
            // pattern as `raw()` above), so `"`/`\` cannot escape into markup —
            // Typst unescapes `\\` back to `\` before mitex sees the TeX.
            // zigmark does not emit the `#import "@preview/mitex..."` line;
            // the consumer's preamble must provide `mi`/`mitex` (use
            // `docHasMath` to decide whether the import is needed).
            try writer.writeAll(if (m.display) "#mitex(\"" else "#mi(\"");
            try writeStringLiteral(writer, m.content);
            try writer.writeAll("\")");
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
                try writer.writeByte('"');
                try writeImageAlt(writer, img.alt_text);
                try writer.writeAll("), caption: [");
                if (img.destination.title) |t| {
                    try writeEscaped(writer, t);
                } else {
                    try writeEscaped(writer, img.alt_text);
                }
                try writer.writeAll("])");
            } else {
                try writer.writeAll("#image(\"");
                try writeStringLiteral(writer, img.destination.url);
                try writer.writeByte('"');
                try writeImageAlt(writer, img.alt_text);
                try writer.writeByte(')');
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
            // `raw(block: true, "…")` with a string literal: content cannot
            // close the block early and inject Typst markup.
            try writer.writeAll("#raw(block: true, \"");
            try writeStringLiteral(writer, cb.content);
            try writer.writeAll("\")\n\n");
        },

        .fenced_code_block => |fcb| {
            mermaid: {
                if (ctx.mermaid) |mfn| {
                    const is_mermaid = if (fcb.language) |l| std.mem.eql(u8, l, "mermaid") or std.mem.eql(u8, l, "mermaidjs") else false;
                    if (!is_mermaid) break :mermaid;
                    const svg = mfn(ctx.allocator, fcb.content) catch break :mermaid;
                    defer ctx.allocator.free(svg);
                    // Embed the SVG source directly as a string literal:
                    // `bytes.fromBase64` does not exist in Typst and
                    // `image.decode` is deprecated; `image(bytes("…"))` is the
                    // supported construct (raw newlines are legal in Typst
                    // string literals). The layout/measure wrapper renders the
                    // diagram at its natural size but caps it at the line
                    // width, matching how LaTeX pipelines size images.
                    try writer.writeAll("#{\n  let d = bytes(\"");
                    try writeStringLiteral(writer, svg);
                    // Flat string-concat indentation is intentional
                    // zig fmt: off
                    try writer.writeAll(
                        "\")\n" ++
                        "  layout(size => {\n" ++
                        "    let img = image(d, format: \"svg\")\n" ++
                        "    if measure(img).width > size.width { image(d, format: \"svg\", width: 100%) } else { img }\n" ++
                        "  })\n" ++
                        "}\n\n",
                    );
                    // zig fmt: on
                    return;
                }
            }
            try writer.writeAll("#raw(block: true");
            if (fcb.language) |lang| {
                try writer.writeAll(", lang: \"");
                try writeStringLiteral(writer, lang);
                try writer.writeByte('"');
            }
            try writer.writeAll(", \"");
            try writeStringLiteral(writer, fcb.content);
            try writer.writeAll("\")\n\n");
        },

        // ── Blockquote ───────────────────────────────────────────────────────
        // Render as a left-bordered block with grey text, matching the
        // Eisvogel `mdframed`-based blockquote style.
        .blockquote => |bq| {
            // Flat string-concat indentation is intentional
            // zig fmt: off
            try writer.writeAll(
                "#block(\n" ++
                "  inset: (left: 12pt, top: 4pt, bottom: 4pt),\n" ++
                "  stroke: (left: (thickness: 3pt, paint: rgb(\"#DDDDDD\"))),\n" ++
                "  text(fill: rgb(\"#777777\"))[\n",
            );
            // zig fmt: on
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
        // Aligned prongs are intentional
        // zig fmt: off
        switch (col_align) {
            .none   => try writer.writeAll("auto"),
            .left   => try writer.writeAll("left"),
            .center => try writer.writeAll("center"),
            .right  => try writer.writeAll("right"),
        }
        // zig fmt: on
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
    // Hand-formatted Typst emission; keep exact string indentation
    // zig fmt: off
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
    try writer.writeAll("  paper: \"");
    try writeStringLiteral(writer, opts.paper);
    try writer.writeAll("\",\n");
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
    // `size:` is an unquoted Typst expression — validate it as a length literal.
    // `lang:` is a string literal — escape it.
    try writer.writeAll(
        "#set text(\n" ++
        "  font: (\"Source Sans Pro\", \"Helvetica\", \"Arial\"),\n" ++
        "  size: ",
    );
    try writer.writeAll(lengthOr(opts.fontsize, "11pt"));
    try writer.writeAll(",\n  lang: \"");
    try writeStringLiteral(writer, opts.lang);
    try writer.writeAll("\",\n)\n\n");

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
            .{hexColorOr(opts.linkcolor, "A50000")},
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
            .{hexColorOr(opts.titlepage_color, "1E3A5F")},
        );

        // Title text block.
        try writer.print(
            "    #set text(fill: rgb(\"#{s}\"))\n",
            .{hexColorOr(opts.titlepage_text_color, "FFFFFF")},
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
            .{ opts.titlepage_rule_height, hexColorOr(opts.titlepage_rule_color, "AAAAAA") },
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
        try writer.writeAll("#outline(\n  title: \"");
        try writeStringLiteral(writer, opts.toc_title);
        try writer.print("\",\n  depth: {d},\n)\n\n", .{opts.toc_depth});
    }
    // zig fmt: on
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

// ── Math detection ────────────────────────────────────────────────────────────

/// True if `doc` contains any math inline (`AST.Math`) anywhere in the tree.
///
/// zigmark emits math as `#mi(…)` / `#mitex(…)` calls but never emits the
/// mitex `#import` itself; consumers that supply their own preamble use this
/// to decide whether to add
/// `#import "@preview/mitex:0.2.5": mi, mitex` (or equivalent).
pub fn docHasMath(doc: *const AST.Document) bool {
    return blocksHaveMath(doc.children.items);
}

fn blocksHaveMath(blocks: []const AST.Block) bool {
    for (blocks) |*block| {
        const found = switch (block.*) {
            .paragraph => |*p| inlinesHaveMath(p.children.items),
            .heading => |*h| inlinesHaveMath(h.children.items),
            .blockquote => |*bq| blocksHaveMath(bq.children.items),
            .footnote_definition => |*fd| blocksHaveMath(fd.children.items),
            .list => |*lst| for (lst.items.items) |*item| {
                if (blocksHaveMath(item.children.items)) break true;
            } else false,
            .table => |*tbl| tableHasMath(tbl),
            .code_block, .fenced_code_block, .thematic_break, .html_block => false,
        };
        if (found) return true;
    }
    return false;
}

fn tableHasMath(tbl: *const AST.Table) bool {
    for (tbl.header.cells.items) |*cell|
        if (inlinesHaveMath(cell.children.items)) return true;
    for (tbl.body.items) |*row|
        for (row.cells.items) |*cell|
            if (inlinesHaveMath(cell.children.items)) return true;
    return false;
}

fn inlinesHaveMath(items: []const AST.Inline) bool {
    for (items) |*item| {
        const found = switch (item.*) {
            .math => true,
            .emphasis => |*e| inlinesHaveMath(e.children.items),
            .strong => |*s| inlinesHaveMath(s.children.items),
            .strikethrough => |*s| inlinesHaveMath(s.children.items),
            .link => |*l| inlinesHaveMath(l.children.items),
            else => false,
        };
        if (found) return true;
    }
    return false;
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Render `doc` to an allocator-owned Typst byte slice (body only; no preamble).
///
/// The output is valid as a standalone Typst source file — Typst's default
/// styles will be applied.  For the full Eisvogel-inspired layout use
/// `renderDocument`.
///
/// The caller owns the returned memory and must free it when done.
/// Render `doc` to a writer as Typst markup (body only, no preamble).
pub fn renderToWriter(allocator: Allocator, writer: *std.Io.Writer, doc: AST.Document) !void {
    var ctx = Ctx.init(allocator);
    defer ctx.deinit();
    try collectFootnotes(doc, &ctx);
    for (doc.children.items) |child| {
        if (child == .footnote_definition) continue;
        try renderBlock(writer, child, &ctx);
    }
}

pub fn render(allocator: Allocator, doc: AST.Document) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try renderToWriter(allocator, &aw.writer, doc);
    return aw.toOwnedSlice();
}

/// Render `doc` to a writer as Typst markup (body only, no preamble),
/// converting each mermaid fenced block to an inline Typst `#{ … }` block that
/// embeds the SVG via `image(bytes("…"), format: "svg")` — sized to its
/// natural width but capped at the line width — using the provided renderer.
/// Pass `null` to render mermaid blocks as plain code blocks. The renderer
/// must return memory allocated with `allocator`; it is freed with that
/// allocator after the diagram is emitted, so returning static or
/// externally-owned memory will trigger an invalid free.
pub fn renderToWriterWithMermaid(
    allocator: Allocator,
    writer: *std.Io.Writer,
    doc: AST.Document,
    mermaid: ?*const fn (Allocator, []const u8) anyerror![]const u8,
) !void {
    var ctx = Ctx.init(allocator);
    ctx.mermaid = mermaid;
    defer ctx.deinit();
    try collectFootnotes(doc, &ctx);
    for (doc.children.items) |child| {
        if (child == .footnote_definition) continue;
        try renderBlock(writer, child, &ctx);
    }
}

/// Render `doc` to a writer as a complete Typst document with an
/// Eisvogel-inspired preamble derived from `opts`.
pub fn renderDocumentToWriter(allocator: Allocator, writer: *std.Io.Writer, doc: AST.Document, opts: DocumentOptions) !void {
    var ctx = Ctx.init(allocator);
    defer ctx.deinit();
    try collectFootnotes(doc, &ctx);
    try writePreamble(writer, opts);
    for (doc.children.items) |child| {
        if (child == .footnote_definition) continue;
        try renderBlock(writer, child, &ctx);
    }
}

/// Render `doc` to a writer as a complete Typst document, converting each
/// mermaid fenced block to an inline Typst `#{ … }` block that embeds the SVG
/// via `image(bytes("…"), format: "svg")` — sized to its natural width but
/// capped at the line width — using the provided renderer. The renderer must
/// return memory allocated with `allocator`; it is freed with that allocator
/// after the diagram is emitted, so returning static or externally-owned
/// memory will trigger an invalid free.
pub fn renderDocumentToWriterWithMermaid(
    allocator: Allocator,
    writer: *std.Io.Writer,
    doc: AST.Document,
    opts: DocumentOptions,
    mermaid: ?*const fn (Allocator, []const u8) anyerror![]const u8,
) !void {
    var ctx = Ctx.init(allocator);
    ctx.mermaid = mermaid;
    defer ctx.deinit();
    try collectFootnotes(doc, &ctx);
    try writePreamble(writer, opts);
    for (doc.children.items) |child| {
        if (child == .footnote_definition) continue;
        try renderBlock(writer, child, &ctx);
    }
}

/// Render `doc` as a complete Typst document with an Eisvogel-inspired
/// preamble derived from `opts`.
///
/// The caller owns the returned memory and must free it when done.
pub fn renderDocument(allocator: Allocator, doc: AST.Document, opts: DocumentOptions) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try renderDocumentToWriter(allocator, &aw.writer, doc, opts);
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
    // Emitted via `raw()` so backticks in content cannot break out into markup.
    try ok("`code`", "#raw(\"code\")\n\n");
}

test "fenced code block no lang" {
    try ok("```\nhello\n```", "#raw(block: true, \"hello\")\n\n");
}

test "fenced code block with lang" {
    try ok("```zig\nconst x = 1;\n```", "#raw(block: true, lang: \"zig\", \"const x = 1;\")\n\n");
}

test "code span with backtick cannot break out of raw" {
    // A backtick in the content is escaped inside the string literal, not
    // treated as a raw-mode delimiter.
    try ok("`` a`b ``", "#raw(\"a`b\")\n\n");
}

test "fenced code block content with closing fence stays contained" {
    try ok(
        "````\n```\n#read(\"/etc/passwd\")\n````",
        "#raw(block: true, \"```\n#read(\\\"/etc/passwd\\\")\")\n\n",
    );
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

test "raw HTML is intentionally dropped (no Typst equivalent)" {
    // Downstream (sc2in/policypress#117) relies on this: its build pre-flight
    // flags raw HTML in policy bodies precisely because this renderer omits it
    // while the HTML renderer keeps it, so the site and the PDF would diverge.
    // If this behaviour ever changes, that validation rule should be revisited.
    //
    // Block HTML (`<div>` starts a type-6 HTML block) is dropped whole.
    try ok("<div class=\"note\">\nhidden\n</div>", "");
    // Inline HTML drops only the tags; the enclosed text survives as text.
    try ok("before <span>kept</span> after", "before kept after\n\n");
}

fn okMermaid(src: []const u8, mfn: ?*const fn (std.mem.Allocator, []const u8) anyerror![]const u8, expected: []const u8) !void {
    const allocator = tst.allocator;
    var parser = Parser.init();
    defer parser.deinit(allocator);
    var res = try parser.parseMarkdown(allocator, src);
    defer res.deinit(allocator);
    var ctx = Ctx.init(allocator);
    ctx.mermaid = mfn;
    defer ctx.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    for (res.children.items) |child| try renderBlock(&aw.writer, child, &ctx);
    const out = try aw.toOwnedSlice();
    defer allocator.free(out);
    try tst.expectEqualStrings(expected, out);
}

fn stubSvg(alloc: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
    return alloc.dupe(u8, "<svg>mock</svg>");
}

fn stubSvgError(_: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
    return error.RenderFailed;
}

/// The Typst emitted for a mermaid block whose renderer produced `svg_lit`
/// (already escaped for a Typst string literal).
fn expectedMermaidTypst(comptime svg_lit: []const u8) []const u8 {
    return "#{\n  let d = bytes(\"" ++ svg_lit ++ "\")\n" ++
        "  layout(size => {\n" ++
        "    let img = image(d, format: \"svg\")\n" ++
        "    if measure(img).width > size.width { image(d, format: \"svg\", width: 100%) } else { img }\n" ++
        "  })\n" ++
        "}\n\n";
}

test "mermaid block renders as inline svg image" {
    try okMermaid(
        "```mermaid\ngraph LR\nA-->B\n```",
        stubSvg,
        expectedMermaidTypst("<svg>mock</svg>"),
    );
}

test "mermaidjs block renders as inline svg image" {
    try okMermaid(
        "```mermaidjs\ngraph LR\nA-->B\n```",
        stubSvg,
        expectedMermaidTypst("<svg>mock</svg>"),
    );
}

fn stubSvgSpecials(alloc: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
    // Quotes and backslashes must be escaped in the Typst string literal;
    // raw newlines pass through unchanged (legal in Typst strings).
    return alloc.dupe(u8, "<svg attr=\"a\\b\">\nline2\n</svg>");
}

test "mermaid svg quotes, backslashes, and newlines survive string-literal embedding" {
    try okMermaid(
        "```mermaid\ngraph LR\nA-->B\n```",
        stubSvgSpecials,
        expectedMermaidTypst("<svg attr=\\\"a\\\\b\\\">\nline2\n</svg>"),
    );
}

test "renderToWriterWithMermaid public API" {
    const allocator = tst.allocator;
    var parser = Parser.init();
    defer parser.deinit(allocator);
    var res = try parser.parseMarkdown(allocator, "# T\n\n```mermaid\ngraph LR\nA-->B\n```");
    defer res.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try renderToWriterWithMermaid(allocator, &aw.writer, res, stubSvg);
    const out = try aw.toOwnedSlice();
    defer allocator.free(out);
    try tst.expect(std.mem.indexOf(u8, out, "let d = bytes(\"<svg>mock</svg>\")") != null);
    try tst.expect(std.mem.indexOf(u8, out, "```mermaid") == null);
}

test "mermaid renderer error falls back to code block" {
    try okMermaid(
        "```mermaid\ngraph LR\nA-->B\n```",
        stubSvgError,
        "#raw(block: true, lang: \"mermaid\", \"graph LR\nA-->B\")\n\n",
    );
}

test "mermaid null renderer falls back to code block" {
    try okMermaid(
        "```mermaid\ngraph LR\nA-->B\n```",
        null,
        "#raw(block: true, lang: \"mermaid\", \"graph LR\nA-->B\")\n\n",
    );
}

test "non-mermaid lang unaffected by mermaid renderer" {
    try okMermaid(
        "```zig\nconst x = 1;\n```",
        stubSvg,
        "#raw(block: true, lang: \"zig\", \"const x = 1;\")\n\n",
    );
}

// ── Math tests (opt-in `$…$` / `$$…$$` via mitex) ─────────────────────────────

fn okMath(src: []const u8, expected: []const u8) !void {
    const allocator = tst.allocator;
    var parser = Parser.init();
    parser.math = true;
    defer parser.deinit(allocator);
    var res = try parser.parseMarkdown(allocator, src);
    defer res.deinit(allocator);
    const out = try render(allocator, res);
    defer allocator.free(out);
    try tst.expectEqualStrings(expected, out);
}

test "inline math emits #mi" {
    try okMath("$E=mc^2$", "#mi(\"E=mc^2\")\n\n");
}

test "display math emits #mitex" {
    // LaTeX backslashes become `\\` inside the Typst string literal;
    // Typst unescapes them back to `\` before mitex sees the TeX.
    try okMath("$$\\sum_{i=0}^n i$$", "#mitex(\"\\\\sum_{i=0}^n i\")\n\n");
}

test "inline and display math mixed with text" {
    try okMath(
        "Inline $a+b$ and display: $$\\frac{a}{b}$$",
        "Inline #mi(\"a+b\") and display: #mitex(\"\\\\frac{a}{b}\")\n\n",
    );
}

test "math opener followed by whitespace stays literal" {
    try okMath("a $ b", "a \\$ b\n\n");
}

test "currency dollars stay literal" {
    try okMath("$5 and $6", "\\$5 and \\$6\n\n");
}

test "escaped dollars never open math" {
    try okMath("\\$not math\\$", "\\$not math\\$\n\n");
}

test "dollar inside code span stays literal" {
    try okMath("`$x$`", "#raw(\"$x$\")\n\n");
}

test "unterminated math stays literal" {
    try okMath("$x", "\\$x\n\n");
}

test "math in heading" {
    try okMath("# Euler $e^{i\\pi}$", "= Euler #mi(\"e^{i\\\\pi}\")\n");
}

test "math in table cell" {
    try okMath(
        "| $x^2$ |\n| --- |\n| $y$ |",
        "#table(\n" ++
            "  columns: 1,\n" ++
            "  align: (auto),\n" ++
            "  stroke: rgb(\"#999999\"),\n" ++
            "  table.header(\n" ++
            "    [*#mi(\"x^2\")*],\n" ++
            "  ),\n" ++
            "  [#mi(\"y\")],\n" ++
            ")\n\n",
    );
}

test "math content cannot break out of the Typst string literal" {
    // A quote in the TeX source must stay inside the string literal — the
    // same injection guard as the code-span/raw() tests above.
    try okMath(
        "$\") #read(\"/etc/passwd\") #(\"$",
        "#mi(\"\\\") #read(\\\"/etc/passwd\\\") #(\\\"\")\n\n",
    );
}

test "math off by default keeps dollars as text" {
    try ok("$E=mc^2$", "\\$E=mc^2\\$\n\n");
}

test "docHasMath detects math anywhere in the tree" {
    const allocator = tst.allocator;
    var parser = Parser.init();
    parser.math = true;
    defer parser.deinit(allocator);

    var in_list = try parser.parseMarkdown(allocator, "- item with $x$\n");
    defer in_list.deinit(allocator);
    try tst.expect(docHasMath(&in_list));

    var in_quote = try parser.parseMarkdown(allocator, "> quoted $y$\n");
    defer in_quote.deinit(allocator);
    try tst.expect(docHasMath(&in_quote));

    var none = try parser.parseMarkdown(allocator, "plain $ text and `$x$`\n");
    defer none.deinit(allocator);
    try tst.expect(!docHasMath(&none));
}

// ── Image alt tests (`image(alt:)` for accessibility / PDF-UA) ───────────────

test "image alt maps to image(alt:) in the figure branch" {
    try ok(
        "![a chart](img.png)",
        "#figure(image(\"img.png\", alt: \"a chart\"), caption: [a chart])\n\n",
    );
}

test "image title becomes caption while alt is preserved" {
    try ok(
        "![alt text](img.png \"The Title\")",
        "#figure(image(\"img.png\", alt: \"alt text\"), caption: [The Title])\n\n",
    );
}

test "empty alt omits the alt param (bare image branch)" {
    try ok("![](img.png)", "#image(\"img.png\")\n\n");
}

test "empty alt with title keeps caption but omits alt" {
    try ok("![](img.png \"T\")", "#figure(image(\"img.png\"), caption: [T])\n\n");
}

test "image alt is injection-safe inside the string literal" {
    try ok(
        "![a\\\\b\"c](img.png)",
        "#figure(image(\"img.png\", alt: \"a\\\\b\\\"c\"), caption: [a\\\\b\"c])\n\n",
    );
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
