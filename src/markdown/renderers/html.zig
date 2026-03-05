const std = @import("std");
const Allocator = std.mem.Allocator;
const tst = std.testing;
const mem = std.mem;

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
            try writeEscaped(writer, l.destination.url);
            try writer.writeByte('"');
            if (l.destination.title) |title| {
                try writer.writeAll(" title=\"");
                try writeEscaped(writer, title);
                try writer.writeByte('"');
            }
            try writer.writeByte('>');
            for (l.children.items) |child| try renderInline(writer, child);
            try writer.writeAll("</a>");
        },
        .image => |img| {
            try writer.writeAll("<img src=\"");
            try writeEscaped(writer, img.destination.url);
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
                try writeEscaped(writer, al.url);
                try writer.writeAll("\">");
                try writeEscaped(writer, al.url);
                try writer.writeAll("</a>");
            } else {
                try writer.writeAll("<a href=\"");
                try writeEscaped(writer, al.url);
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

fn renderBlock(writer: anytype, block: AST.Block) !void {
    switch (block) {
        .heading => |h| {
            try writer.print("<h{d}>", .{h.level});
            for (h.children.items) |item| try renderInline(writer, item);
            try writer.print("</h{d}>", .{h.level});
        },
        .paragraph => |p| {
            try writer.writeAll("<p>");
            for (p.children.items) |item| try renderInline(writer, item);
            try writer.writeAll("</p>");
        },
        .thematic_break => try writer.writeAll("<hr />"),
        .code_block => |cb| {
            try writer.writeAll("<pre><code>");
            try writeEscaped(writer, cb.content);
            try writer.writeAll("</code></pre>");
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
            try writer.writeAll("</code></pre>");
        },
        .blockquote => |bq| {
            try writer.writeAll("<blockquote>");
            for (bq.children.items) |child| try renderBlock(writer, child);
            try writer.writeAll("</blockquote>");
        },
        .list => |lst| {
            const tag: []const u8 = if (lst.type == .ordered) "ol" else "ul";
            if (lst.type == .ordered) {
                if (lst.start) |s| {
                    if (s != 1) {
                        try writer.print("<ol start=\"{d}\">", .{s});
                    } else {
                        try writer.writeAll("<ol>");
                    }
                } else {
                    try writer.writeAll("<ol>");
                }
            } else {
                try writer.writeAll("<ul>");
            }
            for (lst.items.items) |item| {
                try writer.writeAll("<li>");
                if (lst.tight) {
                    // Tight: render inline content only (no wrapping <p>)
                    for (item.children.items) |child| {
                        switch (child) {
                            .paragraph => |p| for (p.children.items) |inl| try renderInline(writer, inl),
                            else => try renderBlock(writer, child),
                        }
                    }
                } else {
                    // Loose: render with block structure
                    for (item.children.items) |child| try renderBlock(writer, child);
                }
                try writer.writeAll("</li>");
            }
            try writer.print("</{s}>", .{tag});
        },
        .footnote_definition => |fd| {
            try writer.print("<div class=\"footnote\" id=\"fn:{s}\">", .{fd.label});
            for (fd.children.items) |child| {
                switch (child) {
                    .paragraph => |p| {
                        try writer.print("<p><b>{s}</b>: ", .{fd.label});
                        for (p.children.items) |inl| try renderInline(writer, inl);
                        try writer.writeAll("</p>");
                    },
                    else => try renderBlock(writer, child),
                }
            }
            try writer.writeAll("</div>");
        },
        .html_block => |hb| try writer.writeAll(hb.content),
    }
}

// ── Top-level render ──────────────────────────────────────────────────────────

pub fn render(allocator: Allocator, doc: AST.Document) ![]u8 {
    var buf = std.ArrayList(u8){};
    var writer = buf.writer(allocator);
    for (doc.children.items) |child| try renderBlock(writer, child);
    return buf.toOwnedSlice(allocator);
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
    try ok("# Heading", "<h1>Heading</h1>");
    try ok("## Level 2", "<h2>Level 2</h2>");
    try ok("### Level 3", "<h3>Level 3</h3>");
}

test "setext heading" {
    try ok("Title\n=====", "<h1>Title</h1>");
    try ok("Title\n-----", "<h2>Title</h2>");
}

test "thematic break" {
    try ok("---", "<hr />");
    try ok("***", "<hr />");
    try ok("___", "<hr />");
}

test "paragraph" {
    try ok("Hello world", "<p>Hello world</p>");
}

test "multi-line paragraph with soft break" {
    try ok("line one\nline two", "<p>line one\nline two</p>");
}

test "emphasis and strong" {
    try ok("*em*", "<p><em>em</em></p>");
    try ok("**bold**", "<p><strong>bold</strong></p>");
    try ok("_em_", "<p><em>em</em></p>");
    try ok("__bold__", "<p><strong>bold</strong></p>");
}

test "link" {
    try ok("[text](https://example.com)", "<p><a href=\"https://example.com\">text</a></p>");
}

test "image" {
    try ok("![alt](img.png)", "<p><img src=\"img.png\" alt=\"alt\" /></p>");
}

test "autolink" {
    try ok("<https://example.com>", "<p><a href=\"https://example.com\">https://example.com</a></p>");
}

test "code span" {
    try ok("`code`", "<p><code>code</code></p>");
}

test "indented code block" {
    try ok("    hello", "<pre><code>hello</code></pre>");
}

test "fenced code block" {
    try ok("```\ncode\n```", "<pre><code>code</code></pre>");
    try ok("```zig\nconst x = 1;\n```", "<pre><code class=\"language-zig\">const x = 1;</code></pre>");
}

test "blockquote" {
    try ok("> quote", "<blockquote><p>quote</p></blockquote>");
}

test "tight unordered list" {
    try ok("- a\n- b\n- c", "<ul><li>a</li><li>b</li><li>c</li></ul>");
}

test "loose unordered list" {
    try ok("- a\n\n- b", "<ul><li><p>a</p></li><li><p>b</p></li></ul>");
}

test "ordered list" {
    try ok("1. first\n2. second", "<ol><li>first</li><li>second</li></ol>");
}

test "ordered list non-one start" {
    try ok("3. first\n4. second", "<ol start=\"3\"><li>first</li><li>second</li></ol>");
}

test "backslash escape" {
    try ok("\\*not em\\*", "<p>*not em*</p>");
}

test "hard break" {
    try ok("line one  \nline two", "<p>line one<br />line two</p>");
}
