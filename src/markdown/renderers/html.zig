//! HTML renderer for the Markdown AST.
//!
//! Serialises an `AST.Document` into CommonMark-compliant HTML.  The
//! output follows the same conventions as the CommonMark reference
//! implementation (`cmark`): UTF-8, self-closing tags for void elements
//! (e.g. `<br />`, `<hr />`), and minimal attribute quoting.
const std = @import("std");
const Allocator = std.mem.Allocator;
const tst = std.testing;

const AST = @import("../ast.zig");
const Parser = @import("../parser.zig");

// ── HTML-escape helper ────────────────────────────────────────────────────────

fn writeEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(c),
        }
    }
}

/// Write a URL with HTML-escaping AND percent-encoding for characters that
/// need it (spaces, non-ASCII, etc.), while preserving already-encoded %XX sequences.
fn writeUrlEncoded(writer: anytype, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '&') {
            try writer.writeAll("&amp;");
        } else if (c == '"') {
            try writer.writeAll("&quot;");
        } else if (c == '\'') {
            try writer.writeAll("%27");
        } else if (c == ' ') {
            try writer.writeAll("%20");
        } else if (c == '\\') {
            // Backslash escape in URL context: if followed by ASCII punct, consume the
            // backslash and encode the punctuation char; otherwise encode the backslash.
            if (i + 1 < s.len and isAsciiPunctuation(s[i + 1])) {
                // Output the escaped character directly (it's the literal char)
                try writer.writeByte(s[i + 1]);
                i += 2;
                continue;
            } else {
                try writer.writeAll("%5C");
            }
        } else if (c == '%' and i + 2 < s.len and isHexDigit(s[i + 1]) and isHexDigit(s[i + 2])) {
            // Already percent-encoded — pass through
            try writer.writeByte('%');
            try writer.writeByte(s[i + 1]);
            try writer.writeByte(s[i + 2]);
            i += 3;
            continue;
        } else if (c >= 0x80) {
            // Non-ASCII: percent-encode each byte
            try writer.print("%{X:0>2}", .{c});
        } else {
            try writer.writeByte(c);
        }
        i += 1;
    }
}

fn isAsciiPunctuation(c: u8) bool {
    return (c >= '!' and c <= '/') or (c >= ':' and c <= '@') or
        (c >= '[' and c <= '`') or (c >= '{' and c <= '~');
}

/// Write text with backslash escape processing + HTML escaping.
/// Backslash-escaped ASCII punctuation chars have the backslash removed.
fn writeEscapedWithBackslash(writer: anytype, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and isAsciiPunctuation(s[i + 1])) {
            // Write the escaped character with HTML escaping
            switch (s[i + 1]) {
                '&' => try writer.writeAll("&amp;"),
                '<' => try writer.writeAll("&lt;"),
                '>' => try writer.writeAll("&gt;"),
                '"' => try writer.writeAll("&quot;"),
                else => try writer.writeByte(s[i + 1]),
            }
            i += 2;
        } else {
            switch (c) {
                '&' => try writer.writeAll("&amp;"),
                '<' => try writer.writeAll("&lt;"),
                '>' => try writer.writeAll("&gt;"),
                '"' => try writer.writeAll("&quot;"),
                else => try writer.writeByte(c),
            }
            i += 1;
        }
    }
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

// ── Inline renderer ───────────────────────────────────────────────────────────

fn renderInline(writer: anytype, item: AST.Inline) !void {
    switch (item) {
        .text => |t| try writer.writeAll(t.content),
        .soft_break => try writer.writeByte('\n'),
        .hard_break => try writer.writeAll("<br />"),
        .code_span => |cs| {
            try writer.writeAll("<code>");
            try writeEscaped(writer, cs.content);
            try writer.writeAll("</code>");
        },
        .emphasis => |e| {
            try writer.writeAll("<em>");
            for (e.children.items) |child| try renderInline(writer, child);
            try writer.writeAll("</em>");
        },
        .strong => |s| {
            try writer.writeAll("<strong>");
            for (s.children.items) |child| try renderInline(writer, child);
            try writer.writeAll("</strong>");
        },
        .link => |l| {
            try writer.writeAll("<a href=\"");
            try writeUrlEncoded(writer, l.destination.url);
            try writer.writeByte('"');
            if (l.destination.title) |title| {
                try writer.writeAll(" title=\"");
                try writeEscapedWithBackslash(writer, title);
                try writer.writeByte('"');
            }
            try writer.writeByte('>');
            for (l.children.items) |child| try renderInline(writer, child);
            try writer.writeAll("</a>");
        },
        .image => |img| {
            try writer.writeAll("<img src=\"");
            try writeUrlEncoded(writer, img.destination.url);
            try writer.writeAll("\" alt=\"");
            try writeEscaped(writer, img.alt_text);
            try writer.writeByte('"');
            if (img.destination.title) |title| {
                try writer.writeAll(" title=\"");
                try writeEscaped(writer, title);
                try writer.writeByte('"');
            }
            try writer.writeAll(" />");
        },
        .autolink => |al| {
            if (al.is_email) {
                try writer.writeAll("<a href=\"mailto:");
                try writeUrlEncoded(writer, al.url);
                try writer.writeAll("\">");
                try writeEscaped(writer, al.url);
                try writer.writeAll("</a>");
            } else {
                try writer.writeAll("<a href=\"");
                try writeUrlEncoded(writer, al.url);
                try writer.writeAll("\">");
                try writeEscaped(writer, al.url);
                try writer.writeAll("</a>");
            }
        },
        .footnote_reference => |fr| {
            try writer.print("<a href=\"#fn:{s}\" class=\"footnote-ref\">{s}</a>", .{ fr.label, fr.label });
        },
        .html_in_line => |hi| try writer.writeAll(hi.content),
    }
}

// ── Block renderer ────────────────────────────────────────────────────────────

fn renderBlock(writer: *std.Io.Writer, block: AST.Block) !void {
    switch (block) {
        .heading => |h| {
            try writer.print("<h{d}>", .{h.level});
            for (h.children.items) |item| try renderInline(writer, item);
            try writer.print("</h{d}>\n", .{h.level});
        },
        .paragraph => |p| {
            try writer.writeAll("<p>");
            for (p.children.items) |item| try renderInline(writer, item);
            try writer.writeAll("</p>\n");
        },
        .thematic_break => try writer.writeAll("<hr />\n"),
        .code_block => |cb| {
            try writer.writeAll("<pre><code>");
            try writeEscaped(writer, cb.content);
            try writer.writeAll("\n</code></pre>\n");
        },
        .fenced_code_block => |fcb| {
            if (fcb.language) |lang| {
                try writer.writeAll("<pre><code class=\"language-");
                try writeEscaped(writer, lang);
                try writer.writeAll("\">");
            } else {
                try writer.writeAll("<pre><code>");
            }
            try writeEscaped(writer, fcb.content);
            try writer.writeAll("\n</code></pre>\n");
        },
        .blockquote => |bq| {
            try writer.writeAll("<blockquote>\n");
            for (bq.children.items) |child| try renderBlock(writer, child);
            try writer.writeAll("</blockquote>\n");
        },
        .list => |lst| {
            const tag: []const u8 = if (lst.type == .ordered) "ol" else "ul";
            if (lst.type == .ordered) {
                if (lst.start) |s| {
                    if (s != 1) {
                        try writer.print("<ol start=\"{d}\">\n", .{s});
                    } else {
                        try writer.writeAll("<ol>\n");
                    }
                } else {
                    try writer.writeAll("<ol>\n");
                }
            } else {
                try writer.writeAll("<ul>\n");
            }
            for (lst.items.items) |item| {
                if (lst.tight) {
                    // Check if the item starts with a paragraph
                    const starts_with_para = item.children.items.len > 0 and
                        item.children.items[0] == .paragraph;
                    if (starts_with_para) {
                        try writer.writeAll("<li>");
                    } else {
                        // Item has only block-level children (e.g. code blocks)
                        if (item.children.items.len == 0) {
                            try writer.writeAll("<li>");
                        } else {
                            try writer.writeAll("<li>\n");
                        }
                    }
                    // Tight: render inline content only (no wrapping <p>)
                    var wrote_inline = false;
                    for (item.children.items) |child| {
                        switch (child) {
                            .paragraph => |p| {
                                for (p.children.items) |inl| try renderInline(writer, inl);
                                wrote_inline = true;
                            },
                            else => {
                                // Non-paragraph block: add newline separator
                                if (wrote_inline) {
                                    try writer.writeByte('\n');
                                }
                                wrote_inline = false;
                                try renderBlock(writer, child);
                            },
                        }
                    }
                    try writer.writeAll("</li>\n");
                } else {
                    // Loose: render with block structure
                    if (item.children.items.len == 0) {
                        try writer.writeAll("<li>");
                    } else {
                        try writer.writeAll("<li>\n");
                        for (item.children.items) |child| try renderBlock(writer, child);
                    }
                    try writer.writeAll("</li>\n");
                }
            }
            try writer.print("</{s}>\n", .{tag});
        },
        .footnote_definition => |fd| {
            try writer.print("<div class=\"footnote\" id=\"fn:{s}\">\n", .{fd.label});
            for (fd.children.items) |child| {
                switch (child) {
                    .paragraph => |p| {
                        try writer.print("<p><b>{s}</b>: ", .{fd.label});
                        for (p.children.items) |inl| try renderInline(writer, inl);
                        try writer.writeAll("</p>\n");
                    },
                    else => try renderBlock(writer, child),
                }
            }
            try writer.writeAll("</div>\n");
        },
        .html_block => |hb| try writer.writeAll(hb.content),
    }
}

// ── Top-level render ──────────────────────────────────────────────────────────

/// Render `doc` to an allocator-owned HTML byte slice.
///
/// The caller owns the returned memory and must free it when done.
pub fn render(allocator: Allocator, doc: AST.Document) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    for (doc.children.items) |child| try renderBlock(&aw.writer, child);
    return aw.toOwnedSlice();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn ok(s: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = Parser.init();
    defer parser.deinit(tst.allocator);
    var res = try parser.parseMarkdown(allocator, s);
    defer res.deinit(allocator);
    const out = try render(allocator, res);
    defer allocator.free(out);
    try tst.expectEqualStrings(expected, out);
}

test "heading" {
    try ok("# Heading", "<h1>Heading</h1>\n");
    try ok("## Level 2", "<h2>Level 2</h2>\n");
    try ok("### Level 3", "<h3>Level 3</h3>\n");
}

test "setext heading" {
    try ok("Title\n=====", "<h1>Title</h1>\n");
    try ok("Title\n-----", "<h2>Title</h2>\n");
}

test "thematic break" {
    try ok("---", "<hr />\n");
    try ok("***", "<hr />\n");
    try ok("___", "<hr />\n");
}

test "paragraph" {
    try ok("Hello world", "<p>Hello world</p>\n");
}

test "multi-line paragraph with soft break" {
    try ok("line one\nline two", "<p>line one\nline two</p>\n");
}

test "emphasis and strong" {
    try ok("*em*", "<p><em>em</em></p>\n");
    try ok("**bold**", "<p><strong>bold</strong></p>\n");
    try ok("_em_", "<p><em>em</em></p>\n");
    try ok("__bold__", "<p><strong>bold</strong></p>\n");
}

test "link" {
    try ok("[text](https://example.com)", "<p><a href=\"https://example.com\">text</a></p>\n");
}

test "image" {
    try ok("![alt](img.png)", "<p><img src=\"img.png\" alt=\"alt\" /></p>\n");
}

test "autolink" {
    try ok("<https://example.com>", "<p><a href=\"https://example.com\">https://example.com</a></p>\n");
}

test "code span" {
    try ok("`code`", "<p><code>code</code></p>\n");
}

test "indented code block" {
    try ok("    hello", "<pre><code>hello\n</code></pre>\n");
}

test "fenced code block" {
    try ok("```\ncode\n```", "<pre><code>code\n</code></pre>\n");
    try ok("```zig\nconst x = 1;\n```", "<pre><code class=\"language-zig\">const x = 1;\n</code></pre>\n");
}

test "blockquote" {
    try ok("> quote", "<blockquote>\n<p>quote</p>\n</blockquote>\n");
}

test "tight unordered list" {
    try ok("- a\n- b\n- c", "<ul>\n<li>a</li>\n<li>b</li>\n<li>c</li>\n</ul>\n");
}

test "loose unordered list" {
    try ok("- a\n\n- b", "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n");
}

test "ordered list" {
    try ok("1. first\n2. second", "<ol>\n<li>first</li>\n<li>second</li>\n</ol>\n");
}

test "ordered list non-one start" {
    try ok("3. first\n4. second", "<ol start=\"3\">\n<li>first</li>\n<li>second</li>\n</ol>\n");
}

test "backslash escape" {
    try ok("\\*not em\\*", "<p>*not em*</p>\n");
}

test "hard break" {
    try ok("line one  \nline two", "<p>line one<br />line two</p>\n");
}

test "link reference" {
    try ok("[foo]: /url \"title\"\n\n[foo]", "<p><a href=\"/url\" title=\"title\">foo</a></p>\n");
}

test "link reference forward" {
    try ok("[foo]\n\n[foo]: /url", "<p><a href=\"/url\">foo</a></p>\n");
}

test "link reference collapsed" {
    try ok("[foo]: /url\n\n[foo][]", "<p><a href=\"/url\">foo</a></p>\n");
}

test "link with parens in url" {
    try ok("[link](foo(and(bar)))", "<p><a href=\"foo(and(bar))\">link</a></p>\n");
}

test "link with angle bracket dest" {
    try ok("[link](</my uri>)", "<p><a href=\"/my%20uri\">link</a></p>\n");
}

test "link with title styles" {
    try ok("[link](/url \"title\")", "<p><a href=\"/url\" title=\"title\">link</a></p>\n");
    try ok("[link](/url 'title')", "<p><a href=\"/url\" title=\"title\">link</a></p>\n");
    try ok("[link](/url (title))", "<p><a href=\"/url\" title=\"title\">link</a></p>\n");
}

test "link rejects space in bare url" {
    try ok("[link](/my uri)", "<p>[link](/my uri)</p>\n");
}
