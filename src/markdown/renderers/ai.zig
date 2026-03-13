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
//!   . "…"           Text
//!   E* / E_         Emphasis (marker)
//!   S* / S_         Strong   (marker)
//!   ` "…"           Code span
//!   L(url) / L(url "title")  Link (children indented below)
//!   I(url "alt")    Image
//!   <url>           Autolink
//!   ^label          Footnote reference
//!   BR              Hard break
//!   NL              Soft break
//!   <> "…"          Inline HTML
//!
//! Content is quoted with `"…"` only when it could be ambiguous (text
//! nodes, code spans, HTML).  Structural tags never need quoting.
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
//!     P
//!      . "a"
//!    +
//!     P
//!      . "b"

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

// ── Block renderer ───────────────────────────────────────────────────────────

fn renderBlock(w: anytype, block: AST.Block, depth: usize) !void {
    switch (block) {
        .heading => |h| {
            try writeIndent(w, depth);
            try w.print("H{d}", .{h.level});
            // Collapse single-text-child headings onto one line
            if (h.children.items.len == 1 and h.children.items[0] == .text) {
                try w.writeByte(' ');
                try writeQuoted(w, h.children.items[0].text.content);
                try w.writeByte('\n');
            } else {
                try w.writeByte('\n');
                for (h.children.items) |inl| try renderInline(w, inl, depth + 1);
            }
        },
        .paragraph => |para| {
            // Collapse single-text-child paragraphs
            if (para.children.items.len == 1 and para.children.items[0] == .text) {
                try writeIndent(w, depth);
                try w.writeAll("P ");
                try writeQuoted(w, para.children.items[0].text.content);
                try w.writeByte('\n');
            } else {
                try writeIndent(w, depth);
                try w.writeAll("P\n");
                for (para.children.items) |inl| try renderInline(w, inl, depth + 1);
            }
        },
        .code_block => |cb| {
            try writeIndent(w, depth);
            try w.writeAll("CB\n");
            try writeIndent(w, depth + 1);
            try writeQuoted(w, cb.content);
            try w.writeByte('\n');
        },
        .fenced_code_block => |fcb| {
            try writeIndent(w, depth);
            try w.print("F{c}", .{fcb.fence_char});
            if (fcb.language) |lang| try w.writeAll(lang);
            try w.writeByte('\n');
            // Write code content as indented lines (preserves readability)
            var it = std.mem.splitScalar(u8, fcb.content, '\n');
            while (it.next()) |line| {
                try writeIndent(w, depth + 1);
                try w.writeAll(line);
                try w.writeByte('\n');
            }
        },
        .blockquote => |bq| {
            try writeIndent(w, depth);
            try w.writeAll("BQ\n");
            for (bq.children.items) |child| try renderBlock(w, child, depth + 1);
        },
        .list => |lst| {
            try writeIndent(w, depth);
            if (lst.type == .ordered) {
                if (lst.start) |s| {
                    try w.print("OL={d}", .{s});
                } else {
                    try w.writeAll("OL");
                }
            } else {
                try w.writeAll("UL");
            }
            try w.print(" {s}\n", .{if (lst.tight) "tight" else "loose"});
            for (lst.items.items) |item| {
                try writeIndent(w, depth + 1);
                try w.writeAll("+\n");
                for (item.children.items) |child| try renderBlock(w, child, depth + 2);
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
            for (fd.children.items) |child| try renderBlock(w, child, depth + 1);
        },
    }
}

// ── Inline renderer ──────────────────────────────────────────────────────────

fn renderInline(w: anytype, inl: AST.Inline, depth: usize) !void {
    switch (inl) {
        .text => |t| {
            try writeIndent(w, depth);
            try w.writeAll(". ");
            try writeQuoted(w, t.content);
            try w.writeByte('\n');
        },
        .emphasis => |em| {
            // Collapse single-text-child emphasis inline
            if (em.children.items.len == 1 and em.children.items[0] == .text) {
                try writeIndent(w, depth);
                try w.print("E{c} ", .{em.marker});
                try writeQuoted(w, em.children.items[0].text.content);
                try w.writeByte('\n');
            } else {
                try writeIndent(w, depth);
                try w.print("E{c}\n", .{em.marker});
                for (em.children.items) |child| try renderInline(w, child, depth + 1);
            }
        },
        .strong => |s| {
            if (s.children.items.len == 1 and s.children.items[0] == .text) {
                try writeIndent(w, depth);
                try w.print("S{c} ", .{s.marker});
                try writeQuoted(w, s.children.items[0].text.content);
                try w.writeByte('\n');
            } else {
                try writeIndent(w, depth);
                try w.print("S{c}\n", .{s.marker});
                for (s.children.items) |child| try renderInline(w, child, depth + 1);
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
            try w.writeAll(")\n");
            for (lnk.children.items) |child| try renderInline(w, child, depth + 1);
        },
        .image => |img| {
            try writeIndent(w, depth);
            try w.writeAll("I(");
            try w.writeAll(img.destination.url);
            if (img.destination.title) |title| {
                try w.writeByte(' ');
                try writeQuoted(w, title);
            }
            try w.print(") ", .{});
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
    for (doc.children.items) |block| try renderBlock(&aw.writer, block, 0);
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

test "ai: link with children" {
    try ok("[text](https://example.com)",
        \\P
        \\ L(https://example.com)
        \\  . "text"
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
