//! Token-efficient AST renderer for LLM consumption.
//!
//! Designed to minimise BPE token count while preserving full structural
//! fidelity.  Uses indentation (1 space per level) for nesting, short
//! ASCII type tags, and inline content — no box-drawing characters.
//!
//! ## Format reference
//!
//! Block tags:
//!   H1…H6          Heading (level in the tag)
//!   P               Paragraph
//!   CB              Indented code block
//!   F`lang / F~lang Fenced code block (fence char + info string)
//!   BQ              Blockquote
//!   UL / OL=N       List (OL start number; tight/loose annotation)
//!   +               List item
//!   HR              Thematic break
//!   HTML            Raw HTML block
//!   FN=label        Footnote definition
//!
//! Inline tags:
//!   . "…"           Text (adjacent text nodes merged)
//!   E* / E_         Emphasis (marker; single-child collapses)
//!   S* / S_         Strong   (marker; single-child collapses)
//!   ` "…"           Code span
//!   L(url) "text"   Link (single-text-child collapses; otherwise children below)
//!   I(url) "alt"    Image
//!   <url>           Autolink
//!   ^label          Footnote reference
//!   BR              Hard break
//!   NL              Soft break
//!   <> "…"          Inline HTML
//!
//! Content is quoted with `"…"` only when it could be ambiguous (text
//! nodes, code spans, HTML).  Structural tags never need quoting.
//!
//! ### Optimisations
//!
//! - **Adjacent text merging**: consecutive `.text` nodes (split by the
//!   parser due to failed bracket/delimiter matching) are merged into a
//!   single `. "…"` line.
//! - **Single-child collapsing**: headings, paragraphs, emphasis, strong,
//!   and links with exactly one text child render on one line.
//! - **Code blocks**: fenced content is written as indented lines (no
//!   quoting), trailing empty lines stripped.
//!
//! ### Example
//!
//! Input markdown:
//!   # Title
//!
//!   **bold** and *italic*
//!
//!   - a
//!   - b
//!
//! Output:
//!   H1 "Title"
//!   P
//!    S* "bold"
//!    . " and "
//!    E* "italic"
//!   UL tight
//!    +
//!     P "a"
//!    +
//!     P "b"

const std = @import("std");
const Allocator = std.mem.Allocator;
const tst = std.testing;

const AST = @import("../ast.zig");
const Parser = @import("../parser.zig");

// ── Helpers ──────────────────────────────────────────────────────────────────

fn writeIndent(w: anytype, depth: usize) !void {
    for (0..depth) |_| try w.writeByte(' ');
}

/// Write a quoted string, escaping embedded `"` and control chars.
fn writeQuoted(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Merge adjacent `.text` inlines into a single string.
/// Returns the content and number of inlines consumed (always >= 1).
fn mergedTextRun(items: []const AST.Inline, start: usize, allocator: Allocator) !struct { text: []const u8, consumed: usize, allocated: bool } {
    // First node must be .text
    const first = items[start].text.content;
    var end = start + 1;
    while (end < items.len) {
        if (items[end] != .text) break;
        end += 1;
    }
    const consumed = end - start;
    if (consumed == 1) return .{ .text = first, .consumed = 1, .allocated = false };

    // Multiple adjacent text nodes — merge
    var buf = std.ArrayList(u8){};
    for (items[start..end]) |item| try buf.appendSlice(allocator, item.text.content);
    return .{ .text = try buf.toOwnedSlice(allocator), .consumed = consumed, .allocated = true };
}

/// Check if a slice of inlines is effectively a single text run
/// (all nodes are .text, no structural inlines mixed in).
fn isSingleTextRun(items: []const AST.Inline) bool {
    if (items.len == 0) return false;
    for (items) |item| if (item != .text) return false;
    return true;
}

/// Collect the merged text content of a pure text run.
fn collectTextRun(items: []const AST.Inline, allocator: Allocator) !struct { text: []const u8, allocated: bool } {
    if (items.len == 1) return .{ .text = items[0].text.content, .allocated = false };
    var buf = std.ArrayList(u8){};
    for (items) |item| try buf.appendSlice(allocator, item.text.content);
    return .{ .text = try buf.toOwnedSlice(allocator), .allocated = true };
}

// ── Block renderer ───────────────────────────────────────────────────────────

fn renderBlock(w: anytype, block: AST.Block, depth: usize, allocator: Allocator) !void {
    switch (block) {
        .table => {},

        .heading => |h| {
            try writeIndent(w, depth);
            try w.print("H{d}", .{h.level});
            if (isSingleTextRun(h.children.items)) {
                const run = try collectTextRun(h.children.items, allocator);
                defer if (run.allocated) allocator.free(run.text);
                try w.writeByte(' ');
                try writeQuoted(w, run.text);
                try w.writeByte('\n');
            } else if (h.children.items.len == 0) {
                try w.writeByte('\n');
            } else {
                try w.writeByte('\n');
                try renderInlineList(w, h.children.items, depth + 1, allocator);
            }
        },
        .paragraph => |para| {
            try writeIndent(w, depth);
            if (isSingleTextRun(para.children.items)) {
                const run = try collectTextRun(para.children.items, allocator);
                defer if (run.allocated) allocator.free(run.text);
                try w.writeAll("P ");
                try writeQuoted(w, run.text);
                try w.writeByte('\n');
            } else if (para.children.items.len == 0) {
                try w.writeAll("P\n");
            } else {
                try w.writeAll("P\n");
                try renderInlineList(w, para.children.items, depth + 1, allocator);
            }
        },
        .code_block => |cb| {
            try writeIndent(w, depth);
            try w.writeAll("CB ");
            try writeQuoted(w, cb.content);
            try w.writeByte('\n');
        },
        .fenced_code_block => |fcb| {
            try writeIndent(w, depth);
            try w.print("F{c}", .{fcb.fence_char});
            if (fcb.language) |lang| try w.writeAll(lang);
            try w.writeByte('\n');
            var it = std.mem.splitScalar(u8, fcb.content, '\n');
            while (it.next()) |line| {
                // Skip trailing empty line from split
                if (line.len == 0 and it.peek() == null) break;
                try writeIndent(w, depth + 1);
                try w.writeAll(line);
                try w.writeByte('\n');
            }
        },
        .blockquote => |bq| {
            try writeIndent(w, depth);
            try w.writeAll("BQ\n");
            for (bq.children.items) |child| try renderBlock(w, child, depth + 1, allocator);
        },
        .list => |lst| {
            try writeIndent(w, depth);
            if (lst.type == .ordered) {
                if (lst.start) |s| try w.print("OL={d}", .{s}) else try w.writeAll("OL");
            } else {
                try w.writeAll("UL");
            }
            try w.print(" {s}\n", .{if (lst.tight) "tight" else "loose"});
            for (lst.items.items) |item| {
                try writeIndent(w, depth + 1);
                try w.writeAll("+\n");
                for (item.children.items) |child| try renderBlock(w, child, depth + 2, allocator);
            }
        },
        .thematic_break => {
            try writeIndent(w, depth);
            try w.writeAll("HR\n");
        },
        .html_block => |hb| {
            try writeIndent(w, depth);
            try w.writeAll("HTML ");
            try writeQuoted(w, hb.content);
            try w.writeByte('\n');
        },
        .footnote_definition => |fd| {
            try writeIndent(w, depth);
            try w.print("FN={s}\n", .{fd.label});
            for (fd.children.items) |child| try renderBlock(w, child, depth + 1, allocator);
        },
    }
}

// ── Inline renderer ──────────────────────────────────────────────────────────

/// Render a list of inlines, merging adjacent text nodes.
fn renderInlineList(w: anytype, items: []const AST.Inline, depth: usize, allocator: Allocator) !void {
    var i: usize = 0;
    while (i < items.len) {
        if (items[i] == .text) {
            const run = try mergedTextRun(items, i, allocator);
            defer if (run.allocated) allocator.free(run.text);
            try writeIndent(w, depth);
            try w.writeAll(". ");
            try writeQuoted(w, run.text);
            try w.writeByte('\n');
            i += run.consumed;
        } else {
            try renderInline(w, items[i], depth, allocator);
            i += 1;
        }
    }
}

fn renderInline(w: anytype, inl: AST.Inline, depth: usize, allocator: Allocator) anyerror!void {
    switch (inl) {
        .text => |t| {
            try writeIndent(w, depth);
            try w.writeAll(". ");
            try writeQuoted(w, t.content);
            try w.writeByte('\n');
        },
        .emphasis => |em| {
            try writeIndent(w, depth);
            try w.print("E{c}", .{em.marker});
            if (isSingleTextRun(em.children.items)) {
                const run = try collectTextRun(em.children.items, allocator);
                defer if (run.allocated) allocator.free(run.text);
                try w.writeByte(' ');
                try writeQuoted(w, run.text);
                try w.writeByte('\n');
            } else {
                try w.writeByte('\n');
                try renderInlineList(w, em.children.items, depth + 1, allocator);
            }
        },
        .strong => |s| {
            try writeIndent(w, depth);
            try w.print("S{c}", .{s.marker});
            if (isSingleTextRun(s.children.items)) {
                const run = try collectTextRun(s.children.items, allocator);
                defer if (run.allocated) allocator.free(run.text);
                try w.writeByte(' ');
                try writeQuoted(w, run.text);
                try w.writeByte('\n');
            } else {
                try w.writeByte('\n');
                try renderInlineList(w, s.children.items, depth + 1, allocator);
            }
        },
        .code_span => |cs| {
            try writeIndent(w, depth);
            try w.writeAll("` ");
            try writeQuoted(w, cs.content);
            try w.writeByte('\n');
        },
        .link => |lnk| {
            try writeIndent(w, depth);
            try w.writeAll("L(");
            try w.writeAll(lnk.destination.url);
            if (lnk.destination.title) |title| {
                try w.writeByte(' ');
                try writeQuoted(w, title);
            }
            try w.writeByte(')');
            // Collapse single-text-child links onto one line
            if (isSingleTextRun(lnk.children.items)) {
                const run = try collectTextRun(lnk.children.items, allocator);
                defer if (run.allocated) allocator.free(run.text);
                try w.writeByte(' ');
                try writeQuoted(w, run.text);
                try w.writeByte('\n');
            } else {
                try w.writeByte('\n');
                try renderInlineList(w, lnk.children.items, depth + 1, allocator);
            }
        },
        .image => |img| {
            try writeIndent(w, depth);
            try w.writeAll("I(");
            try w.writeAll(img.destination.url);
            if (img.destination.title) |title| {
                try w.writeByte(' ');
                try writeQuoted(w, title);
            }
            try w.writeAll(") ");
            try writeQuoted(w, img.alt_text);
            try w.writeByte('\n');
        },
        .autolink => |al| {
            try writeIndent(w, depth);
            try w.print("<{s}>\n", .{al.url});
        },
        .footnote_reference => |fr| {
            try writeIndent(w, depth);
            try w.print("^{s}\n", .{fr.label});
        },
        .hard_break => {
            try writeIndent(w, depth);
            try w.writeAll("BR\n");
        },
        .soft_break => {
            try writeIndent(w, depth);
            try w.writeAll("NL\n");
        },
        .html_in_line => |hi| {
            try writeIndent(w, depth);
            try w.writeAll("<> ");
            try writeQuoted(w, hi.content);
            try w.writeByte('\n');
        },
    }
}

// ── Top-level render ─────────────────────────────────────────────────────────

pub fn render(allocator: Allocator, doc: AST.Document) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    for (doc.children.items) |block| try renderBlock(&aw.writer, block, 0, allocator);
    return aw.toOwnedSlice();
}

// ── Tests ────────────────────────────────────────────────────────────────────

fn ok(markdown: []const u8, expected: []const u8) !void {
    const allocator = tst.allocator;
    var parser = Parser.init();
    defer parser.deinit(allocator);
    var doc = try parser.parseMarkdown(allocator, markdown);
    defer doc.deinit(allocator);
    const out = try render(allocator, doc);
    defer allocator.free(out);
    try tst.expectEqualStrings(expected, out);
}

test "ai: heading collapses to one line" {
    try ok("# Title",
        \\H1 "Title"
        \\
    );
}

test "ai: paragraph with emphasis" {
    try ok("**bold** and *italic*",
        \\P
        \\ S* "bold"
        \\ . " and "
        \\ E* "italic"
        \\
    );
}

test "ai: single-text paragraph collapses" {
    try ok("Hello world",
        \\P "Hello world"
        \\
    );
}

test "ai: unordered list" {
    try ok("- a\n- b",
        \\UL tight
        \\ +
        \\  P "a"
        \\ +
        \\  P "b"
        \\
    );
}

test "ai: fenced code block" {
    try ok("```zig\nconst x = 1;\n```",
        \\F`zig
        \\ const x = 1;
        \\
    );
}

test "ai: blockquote" {
    try ok("> quote",
        \\BQ
        \\ P "quote"
        \\
    );
}

test "ai: link collapses to one line" {
    try ok("[text](https://example.com)",
        \\P
        \\ L(https://example.com) "text"
        \\
    );
}

test "ai: link with mixed children" {
    try ok("[**bold** link](https://example.com)",
        \\P
        \\ L(https://example.com)
        \\  S* "bold"
        \\  . " link"
        \\
    );
}

test "ai: image" {
    try ok("![alt](img.png)",
        \\P
        \\ I(img.png) "alt"
        \\
    );
}

test "ai: hard break" {
    try ok("line one  \nline two",
        \\P
        \\ . "line one"
        \\ BR
        \\ . "line two"
        \\
    );
}

test "ai: thematic break" {
    try ok("---",
        \\HR
        \\
    );
}

test "ai: autolink" {
    try ok("<https://example.com>",
        \\P
        \\ <https://example.com>
        \\
    );
}

test "ai: multiple blocks" {
    try ok("# Title\n\nParagraph text.\n\n---",
        \\H1 "Title"
        \\P "Paragraph text."
        \\HR
        \\
    );
}

test "ai: ordered list" {
    try ok("1. first\n2. second",
        \\OL=1 tight
        \\ +
        \\  P "first"
        \\ +
        \\  P "second"
        \\
    );
}

test "ai: nested emphasis in heading" {
    try ok("# Hello *world*",
        \\H1
        \\ . "Hello "
        \\ E* "world"
        \\
    );
}

test "ai: code span" {
    try ok("Use `code` here",
        \\P
        \\ . "Use "
        \\ ` "code"
        \\ . " here"
        \\
    );
}

test "ai: adjacent text nodes merge" {
    // The parser splits [x] into "[" + "x] " due to failed bracket matching.
    // The renderer should merge them back.
    try ok("- [x] done",
        \\UL tight
        \\ +
        \\  P "[x] done"
        \\
    );
}

test "ai: indented code block" {
    try ok("    code here",
        \\CB "code here"
        \\
    );
}

test "ai: footnote" {
    try ok("[^1]\n[^1]: content",
        \\P
        \\ ^1
        \\FN=1
        \\ P "content"
        \\
    );
}
