//! Markdown renderer for the Markdown AST — CommonMark + GFM.
//!
//! Serialises an `AST.Document` back into Markdown text.  The output is
//! normalised:
//!
//!   - Headings are always written in ATX format (`# heading`).
//!   - Indented code blocks are normalised to fenced code blocks.
//!   - Fenced code blocks preserve their original fence character and length.
//!   - Links are always written in inline format `[text](url)` or
//!     `[text](url "title")`, regardless of how they were originally written.
//!   - Blocks are separated by a blank line.
//!
//! GFM extensions rendered:
//!   - Tables  →  `| col | col |\n|---|---|\n| cell | cell |`
//!   - Task list items  →  `- [x] item` / `- [ ] item`
//!   - Strikethrough  →  `~~text~~`
//!   - Extended autolinks  →  bare URL (no angle brackets) for www links
//!   - Footnote definitions  →  `[^label]: content`
//!   - Footnote references  →  `[^label]`
const std = @import("std");
const Allocator = std.mem.Allocator;
const tst = std.testing;

const AST = @import("../ast.zig");
const Parser = @import("../parser.zig");

// ── Markdown escape helpers ───────────────────────────────────────────────────

/// Characters that must be escaped in regular Markdown text.
fn needsEscape(c: u8) bool {
    return switch (c) {
        '\\', '*', '_', '`', '[', ']', '<', '>', '!', '#', '|', '~', '&' => true,
        else => false,
    };
}

/// Write `s` with Markdown special characters backslash-escaped.
fn writeEscapedText(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        if (needsEscape(c)) try writer.writeByte('\\');
        try writer.writeByte(c);
    }
}

/// Write a link URL.  We pass it through verbatim — the URL was already
/// decoded/normalised by the parser, so no additional escaping is needed
/// beyond wrapping with angle brackets when the URL contains spaces or parens.
fn writeLinkUrl(writer: anytype, url: []const u8) !void {
    // If the URL contains spaces or unbalanced parentheses, wrap in angle brackets.
    var needs_brackets = false;
    for (url) |c| {
        if (c == ' ' or c == '\t' or c == '\n') {
            needs_brackets = true;
            break;
        }
    }
    if (needs_brackets) {
        try writer.writeByte('<');
        try writer.writeAll(url);
        try writer.writeByte('>');
    } else {
        try writer.writeAll(url);
    }
}

/// Write a link title, double-quote-wrapped with inner double quotes escaped.
fn writeLinkTitle(writer: anytype, title: []const u8) !void {
    try writer.writeByte('"');
    for (title) |c| {
        if (c == '"') try writer.writeByte('\\');
        try writer.writeByte(c);
    }
    try writer.writeByte('"');
}

// ── Inline renderer ───────────────────────────────────────────────────────────

fn renderInline(writer: anytype, item: AST.Inline) !void {
    switch (item) {
        .text => |t| try writeEscapedText(writer, t.content),

        .soft_break => try writer.writeByte('\n'),

        .hard_break => try writer.writeAll("  \n"),

        .code_span => |cs| {
            // Use double backticks if the content contains a backtick.
            const has_backtick = std.mem.indexOfScalar(u8, cs.content, '`') != null;
            if (has_backtick) {
                try writer.writeAll("`` ");
                try writer.writeAll(cs.content);
                try writer.writeAll(" ``");
            } else {
                try writer.writeByte('`');
                try writer.writeAll(cs.content);
                try writer.writeByte('`');
            }
        },

        .emphasis => |e| {
            const m = e.marker;
            try writer.writeByte(m);
            for (e.children.items) |child| try renderInline(writer, child);
            try writer.writeByte(m);
        },

        .strong => |s| {
            const m = s.marker;
            try writer.writeByte(m);
            try writer.writeByte(m);
            for (s.children.items) |child| try renderInline(writer, child);
            try writer.writeByte(m);
            try writer.writeByte(m);
        },

        .strikethrough => |s| {
            try writer.writeAll("~~");
            for (s.children.items) |child| try renderInline(writer, child);
            try writer.writeAll("~~");
        },

        .link => |l| {
            try writer.writeByte('[');
            for (l.children.items) |child| try renderInline(writer, child);
            try writer.writeAll("](");
            try writeLinkUrl(writer, l.destination.url);
            if (l.destination.title) |title| {
                try writer.writeByte(' ');
                try writeLinkTitle(writer, title);
            }
            try writer.writeByte(')');
        },

        .image => |img| {
            try writer.writeAll("![");
            try writer.writeAll(img.alt_text);
            try writer.writeAll("](");
            try writeLinkUrl(writer, img.destination.url);
            if (img.destination.title) |title| {
                try writer.writeByte(' ');
                try writeLinkTitle(writer, title);
            }
            try writer.writeByte(')');
        },

        .autolink => |al| {
            if (al.is_gfm_www) {
                // GFM extended www autolink: bare URL without angle brackets
                try writer.writeAll(al.url);
            } else {
                try writer.writeByte('<');
                try writer.writeAll(al.url);
                try writer.writeByte('>');
            }
        },

        .footnote_reference => |fr| {
            try writer.writeAll("[^");
            try writer.writeAll(fr.label);
            try writer.writeByte(']');
        },

        .html_in_line => |hi| try writer.writeAll(hi.content),
    }
}

// ── Inline list renderer ──────────────────────────────────────────────────────

fn renderInlines(writer: anytype, inlines: []const AST.Inline) !void {
    for (inlines) |item| try renderInline(writer, item);
}

// ── Block renderer ────────────────────────────────────────────────────────────

/// Render a single block to `writer`.  Each block ends with exactly one `\n`;
/// the caller inserts the blank-line separator `\n` between blocks.
fn renderBlock(alloc: Allocator, writer: anytype, block: AST.Block) !void {
    switch (block) {
        .paragraph => |p| {
            try renderInlines(writer, p.children.items);
            try writer.writeByte('\n');
        },

        .heading => |h| {
            // ATX heading: `## text`
            var i: u8 = 0;
            while (i < h.level) : (i += 1) try writer.writeByte('#');
            try writer.writeByte(' ');
            try renderInlines(writer, h.children.items);
            try writer.writeByte('\n');
        },

        .code_block => |cb| {
            // Normalise indented code blocks to fenced format (``` ... ```)
            try writer.writeAll("```\n");
            try writer.writeAll(cb.content);
            if (cb.content.len > 0 and cb.content[cb.content.len - 1] != '\n') {
                try writer.writeByte('\n');
            }
            try writer.writeAll("```\n");
        },

        .fenced_code_block => |fcb| {
            // Preserve original fence character and length
            var i: usize = 0;
            while (i < fcb.fence_length) : (i += 1) try writer.writeByte(fcb.fence_char);
            if (fcb.language) |lang| try writer.writeAll(lang);
            try writer.writeByte('\n');
            if (fcb.content.len > 0) {
                try writer.writeAll(fcb.content);
                if (fcb.content[fcb.content.len - 1] != '\n') {
                    try writer.writeByte('\n');
                }
            }
            i = 0;
            while (i < fcb.fence_length) : (i += 1) try writer.writeByte(fcb.fence_char);
            try writer.writeByte('\n');
        },

        .blockquote => |bq| {
            // Buffer children, then prefix every line with "> "
            var inner: std.Io.Writer.Allocating = .init(alloc);
            defer inner.deinit();
            for (bq.children.items, 0..) |child, idx| {
                if (idx > 0) try inner.writer.writeByte('\n');
                try renderBlock(alloc, &inner.writer, child);
            }
            const buf = try inner.toOwnedSlice();
            defer alloc.free(buf);

            var line_start: usize = 0;
            for (buf, 0..) |c, i| {
                if (c == '\n') {
                    const line = buf[line_start..i];
                    if (line.len == 0) {
                        try writer.writeAll(">\n");
                    } else {
                        try writer.writeAll("> ");
                        try writer.writeAll(line);
                        try writer.writeByte('\n');
                    }
                    line_start = i + 1;
                }
            }
            // Handle any remaining content without a trailing newline
            if (line_start < buf.len) {
                const line = buf[line_start..];
                try writer.writeAll("> ");
                try writer.writeAll(line);
                try writer.writeByte('\n');
            }
        },

        .list => |lst| {
            const is_ordered = lst.type == .ordered;
            const start_num: usize = lst.start orelse 1;

            for (lst.items.items, 0..) |item, idx| {
                // Blank line between items in a loose list
                if (!lst.tight and idx > 0) try writer.writeByte('\n');

                // Build item prefix
                var prefix_buf: [16]u8 = undefined;
                const prefix: []const u8 = if (is_ordered) blk: {
                    const num = start_num + idx;
                    break :blk std.fmt.bufPrint(&prefix_buf, "{d}. ", .{num}) catch unreachable;
                } else "- ";

                // Task list checkbox
                var task_prefix: []const u8 = "";
                if (item.task_list_checked) |checked| {
                    task_prefix = if (checked) "[x] " else "[ ] ";
                }

                // Indent for continuation lines
                // Unordered: 2 spaces, ordered: prefix.len spaces
                const indent_len = prefix.len;
                var indent_buf: [16]u8 = @splat(' ');
                const indent: []const u8 = indent_buf[0..indent_len];

                // Buffer the item's block children
                var item_buf: std.Io.Writer.Allocating = .init(alloc);
                defer item_buf.deinit();

                for (item.children.items, 0..) |child, cidx| {
                    if (!item.tight and cidx > 0) try item_buf.writer.writeByte('\n');
                    try renderBlock(alloc, &item_buf.writer, child);
                }

                const content = try item_buf.toOwnedSlice();
                defer alloc.free(content);

                // Write the first line with the list prefix (and optional task prefix)
                var first_line = true;
                var line_start: usize = 0;
                for (content, 0..) |c, i| {
                    if (c == '\n') {
                        const line = content[line_start..i];
                        if (first_line) {
                            try writer.writeAll(prefix);
                            try writer.writeAll(task_prefix);
                            try writer.writeAll(line);
                            first_line = false;
                        } else {
                            // Continuation: indent if non-empty
                            if (line.len == 0) {
                                try writer.writeByte('\n');
                            } else {
                                try writer.writeAll(indent);
                                try writer.writeAll(line);
                            }
                        }
                        try writer.writeByte('\n');
                        line_start = i + 1;
                    }
                }
                // Remaining content without trailing newline
                if (line_start < content.len) {
                    const line = content[line_start..];
                    if (first_line) {
                        try writer.writeAll(prefix);
                        try writer.writeAll(task_prefix);
                        try writer.writeAll(line);
                    } else {
                        try writer.writeAll(indent);
                        try writer.writeAll(line);
                    }
                    try writer.writeByte('\n');
                }
            }
        },

        .thematic_break => try writer.writeAll("---\n"),

        .html_block => |hb| try writer.writeAll(hb.content),

        .footnote_definition => |fd| {
            // First line: `[^label]: first block content`
            // Continuation lines indented by 4 spaces
            var first = true;
            for (fd.children.items) |child| {
                var child_buf: std.Io.Writer.Allocating = .init(alloc);
                defer child_buf.deinit();
                try renderBlock(alloc, &child_buf.writer, child);
                const content = try child_buf.toOwnedSlice();
                defer alloc.free(content);

                var line_start: usize = 0;
                for (content, 0..) |c, i| {
                    if (c == '\n') {
                        const line = content[line_start..i];
                        if (first) {
                            try writer.writeAll("[^");
                            try writer.writeAll(fd.label);
                            try writer.writeAll("]: ");
                            try writer.writeAll(line);
                            first = false;
                        } else {
                            if (line.len == 0) {
                                try writer.writeByte('\n');
                            } else {
                                try writer.writeAll("    ");
                                try writer.writeAll(line);
                            }
                        }
                        try writer.writeByte('\n');
                        line_start = i + 1;
                    }
                }
                if (line_start < content.len) {
                    const line = content[line_start..];
                    if (first) {
                        try writer.writeAll("[^");
                        try writer.writeAll(fd.label);
                        try writer.writeAll("]: ");
                        try writer.writeAll(line);
                        first = false;
                    } else {
                        try writer.writeAll("    ");
                        try writer.writeAll(line);
                    }
                    try writer.writeByte('\n');
                }
            }
            // Edge case: empty footnote definition
            if (first) {
                try writer.writeAll("[^");
                try writer.writeAll(fd.label);
                try writer.writeAll("]:\n");
            }
        },

        .table => |tbl| {
            const ncols = tbl.alignments.items.len;

            // Header row
            try writer.writeByte('|');
            for (tbl.header.cells.items) |cell| {
                try writer.writeByte(' ');
                try renderInlines(writer, cell.children.items);
                try writer.writeAll(" |");
            }
            // Pad missing header cells
            if (tbl.header.cells.items.len < ncols) {
                var pad = tbl.header.cells.items.len;
                while (pad < ncols) : (pad += 1) try writer.writeAll("  |");
            }
            try writer.writeByte('\n');

            // Delimiter row
            try writer.writeByte('|');
            for (tbl.alignments.items) |al| {
                switch (al) {
                    .none => try writer.writeAll("---|"),
                    .left => try writer.writeAll(":---|"),
                    .center => try writer.writeAll(":---:|"),
                    .right => try writer.writeAll("---:|"),
                }
            }
            try writer.writeByte('\n');

            // Body rows
            for (tbl.body.items) |row| {
                try writer.writeByte('|');
                for (row.cells.items) |cell| {
                    try writer.writeByte(' ');
                    try renderInlines(writer, cell.children.items);
                    try writer.writeAll(" |");
                }
                // Pad missing body cells
                if (row.cells.items.len < ncols) {
                    var pad = row.cells.items.len;
                    while (pad < ncols) : (pad += 1) try writer.writeAll("  |");
                }
                try writer.writeByte('\n');
            }
        },
    }
}

// ── Top-level render ──────────────────────────────────────────────────────────

/// Render `doc` to an allocator-owned Markdown byte slice.
///
/// The output is normalised CommonMark + GFM Markdown: ATX headings, fenced
/// code blocks, and inline-style links.  Blocks are separated by blank lines.
///
/// The caller owns the returned memory and must free it when done.
pub fn render(allocator: Allocator, doc: AST.Document) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    for (doc.children.items, 0..) |block, idx| {
        if (idx > 0) try w.writeByte('\n');
        try renderBlock(allocator, w, block);
    }

    return aw.toOwnedSlice();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn parse(alloc: Allocator, src: []const u8) !AST.Document {
    var parser = Parser.init();
    defer parser.deinit(alloc);
    return parser.parseMarkdown(alloc, src);
}

fn roundtrip(alloc: Allocator, input: []const u8) ![]u8 {
    var doc = try parse(alloc, input);
    defer doc.deinit(alloc);
    return render(alloc, doc);
}

fn expectMd(input: []const u8, expected: []const u8) !void {
    const alloc = tst.allocator;
    const out = try roundtrip(alloc, input);
    defer alloc.free(out);
    try tst.expectEqualStrings(expected, out);
}

test "atx heading round-trip" {
    try expectMd("# Heading 1", "# Heading 1\n");
    try expectMd("## Heading 2", "## Heading 2\n");
    try expectMd("### Heading 3", "### Heading 3\n");
}

test "setext heading normalised to atx" {
    try expectMd("Title\n=====", "# Title\n");
    try expectMd("Title\n-----", "## Title\n");
}

test "paragraph" {
    try expectMd("Hello world", "Hello world\n");
}

test "multiple blocks separated by blank line" {
    try expectMd("# Title\n\nParagraph.", "# Title\n\nParagraph.\n");
}

test "thematic break" {
    try expectMd("---", "---\n");
    try expectMd("***", "---\n");
}

test "indented code block normalised to fenced" {
    try expectMd("    hello\n    world", "```\nhello\nworld\n```\n");
}

test "fenced code block preserved" {
    try expectMd("```\ncode\n```", "```\ncode\n```\n");
    try expectMd("```zig\nconst x = 1;\n```", "```zig\nconst x = 1;\n```\n");
}

test "fenced code block with tilde fence" {
    try expectMd("~~~\ncode\n~~~", "~~~\ncode\n~~~\n");
}

test "blockquote" {
    try expectMd("> hello", "> hello\n");
}

test "tight unordered list" {
    try expectMd("- a\n- b\n- c", "- a\n- b\n- c\n");
}

test "loose unordered list" {
    try expectMd("- a\n\n- b", "- a\n\n- b\n");
}

test "ordered list" {
    try expectMd("1. first\n2. second", "1. first\n2. second\n");
}

test "ordered list custom start" {
    try expectMd("3. first\n4. second", "3. first\n4. second\n");
}

test "emphasis round-trip" {
    try expectMd("*em*", "*em*\n");
}

test "strong round-trip" {
    try expectMd("**bold**", "**bold**\n");
}

test "strikethrough" {
    try expectMd("~~strike~~", "~~strike~~\n");
}

test "code span no backtick" {
    try expectMd("`code`", "`code`\n");
}

test "inline link normalised" {
    try expectMd("[text](https://example.com)", "[text](https://example.com)\n");
}

test "inline link with title" {
    try expectMd("[text](/url \"title\")", "[text](/url \"title\")\n");
}

test "reference link normalised to inline" {
    try expectMd("[foo]: /url\n\n[foo]", "[foo](/url)\n");
}

test "image" {
    try expectMd("![alt](img.png)", "![alt](img.png)\n");
}

test "autolink" {
    try expectMd("<https://example.com>", "<https://example.com>\n");
}

test "footnote reference" {
    try expectMd("[^note]\n\n[^note]: content", "[^note]\n\n[^note]: content\n");
}

test "hard break" {
    try expectMd("line one  \nline two", "line one  \nline two\n");
}

test "soft break" {
    try expectMd("line one\nline two", "line one\nline two\n");
}

test "html block passthrough" {
    try expectMd("<div>\nhello\n</div>\n", "<div>\nhello\n</div>\n");
}

test "gfm task list" {
    try expectMd("- [x] done\n- [ ] todo", "- [x] done\n- [ ] todo\n");
}

test "gfm table basic" {
    try expectMd(
        "a | b\n---|---\n1 | 2",
        "| a | b |\n|---|---|\n| 1 | 2 |\n",
    );
}
