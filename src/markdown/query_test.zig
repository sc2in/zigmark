const std = @import("std");
const tst = std.testing;

const AST = @import("ast.zig");
const Parser = @import("parser.zig");

// ── Query system tests ──────────────────────────────────────────────────────

fn parse(allocator: std.mem.Allocator, input: []const u8) !AST.Document {
    var p = Parser.init();
    return p.parseMarkdown(allocator, input);
}

test "query: count headings" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc,
        \\# Heading 1
        \\
        \\## Heading 2
        \\
        \\Paragraph text.
        \\
        \\### Heading 3
    );
    defer doc.deinit(alloc);

    const q = doc.get();
    try tst.expectEqual(@as(usize, 3), q.count(.heading));
    try tst.expectEqual(@as(usize, 1), q.count(.paragraph));
    try tst.expectEqual(@as(usize, 0), q.count(.list));
    try tst.expectEqual(@as(usize, 0), q.count(.thematic_break));
}

test "query: count on empty document" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc, "");
    defer doc.deinit(alloc);

    const q = doc.get();
    try tst.expectEqual(@as(usize, 0), q.count(.heading));
    try tst.expectEqual(@as(usize, 0), q.count(.paragraph));
}

test "query: headings returns all levels" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc,
        \\# First
        \\
        \\## Second
        \\
        \\### Third
        \\
        \\## Fourth
    );
    defer doc.deinit(alloc);

    const q = doc.get();
    var all = try q.headings(alloc, null);
    defer all.deinit(alloc);
    try tst.expectEqual(@as(usize, 4), all.items.len);
}

test "query: headings filtered by level" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc,
        \\# H1 A
        \\
        \\## H2 A
        \\
        \\# H1 B
        \\
        \\## H2 B
        \\
        \\### H3
    );
    defer doc.deinit(alloc);

    const q = doc.get();

    var h1s = try q.headings(alloc, 1);
    defer h1s.deinit(alloc);
    try tst.expectEqual(@as(usize, 2), h1s.items.len);

    var h2s = try q.headings(alloc, 2);
    defer h2s.deinit(alloc);
    try tst.expectEqual(@as(usize, 2), h2s.items.len);

    var h3s = try q.headings(alloc, 3);
    defer h3s.deinit(alloc);
    try tst.expectEqual(@as(usize, 1), h3s.items.len);

    var h4s = try q.headings(alloc, 4);
    defer h4s.deinit(alloc);
    try tst.expectEqual(@as(usize, 0), h4s.items.len);
}

test "query: heading level values" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc,
        \\# Title
        \\
        \\## Subtitle
    );
    defer doc.deinit(alloc);

    const q = doc.get();
    var h1s = try q.headings(alloc, 1);
    defer h1s.deinit(alloc);
    try tst.expectEqual(@as(u8, 1), h1s.items[0].level);

    var h2s = try q.headings(alloc, 2);
    defer h2s.deinit(alloc);
    try tst.expectEqual(@as(u8, 2), h2s.items[0].level);
}

test "query: links across paragraphs" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc,
        \\[a](https://a.com)
        \\
        \\[b](https://b.com) and [c](https://c.com)
    );
    defer doc.deinit(alloc);

    const q = doc.get();
    var links = try q.links(alloc);
    defer links.deinit(alloc);
    try tst.expectEqual(@as(usize, 3), links.items.len);
    try tst.expectEqualStrings("https://a.com", links.items[0].destination.url);
    try tst.expectEqualStrings("https://b.com", links.items[1].destination.url);
    try tst.expectEqualStrings("https://c.com", links.items[2].destination.url);
}

test "query: links in headings" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc,
        \\# [Title Link](https://title.com)
    );
    defer doc.deinit(alloc);

    const q = doc.get();
    var links = try q.links(alloc);
    defer links.deinit(alloc);
    try tst.expectEqual(@as(usize, 1), links.items.len);
    try tst.expectEqualStrings("https://title.com", links.items[0].destination.url);
}

test "query: links in blockquotes" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc,
        \\> [quoted link](https://quoted.com)
    );
    defer doc.deinit(alloc);

    const q = doc.get();
    var links = try q.links(alloc);
    defer links.deinit(alloc);
    try tst.expectEqual(@as(usize, 1), links.items.len);
    try tst.expectEqualStrings("https://quoted.com", links.items[0].destination.url);
}

test "query: links in list items" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc,
        \\- [item1](https://one.com)
        \\- [item2](https://two.com)
    );
    defer doc.deinit(alloc);

    const q = doc.get();
    var links = try q.links(alloc);
    defer links.deinit(alloc);
    try tst.expectEqual(@as(usize, 2), links.items.len);
}

test "query: no links returns empty" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc,
        \\Just plain text.
    );
    defer doc.deinit(alloc);

    const q = doc.get();
    var links = try q.links(alloc);
    defer links.deinit(alloc);
    try tst.expectEqual(@as(usize, 0), links.items.len);
}

test "query: blocks filtered by type" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc,
        \\# Heading
        \\
        \\Paragraph.
        \\
        \\---
        \\
        \\Another paragraph.
    );
    defer doc.deinit(alloc);

    const q = doc.get();

    var paras = try q.blocks(alloc, .paragraph);
    defer paras.deinit(alloc);
    try tst.expectEqual(@as(usize, 2), paras.items.len);

    var breaks = try q.blocks(alloc, .thematic_break);
    defer breaks.deinit(alloc);
    try tst.expectEqual(@as(usize, 1), breaks.items.len);
}

test "query: textAt heading[0]" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc,
        \\# My Title
        \\
        \\Content here.
    );
    defer doc.deinit(alloc);

    const q = doc.get();
    const text = try q.textAt(alloc, "heading[0]");
    try tst.expect(text != null);
    try tst.expectEqualStrings("My Title", text.?);
}

test "query: textAt non-heading index" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc,
        \\Paragraph first.
        \\
        \\# Heading second
    );
    defer doc.deinit(alloc);

    const q = doc.get();
    // Block 0 is a paragraph, not a heading
    const text = try q.textAt(alloc, "heading[0]");
    try tst.expect(text == null);
    // Block 1 is the heading
    const text1 = try q.textAt(alloc, "heading[1]");
    try tst.expect(text1 != null);
    try tst.expectEqualStrings("Heading second", text1.?);
}

test "query: textAt invalid path" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc, "# Hello");
    defer doc.deinit(alloc);

    const q = doc.get();
    try tst.expect(try q.textAt(alloc, "invalid") == null);
    try tst.expect(try q.textAt(alloc, "heading[99]") == null);
    try tst.expect(try q.textAt(alloc, "heading[]") == null);
}

test "query: paragraphsWithInlines emphasis" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc,
        \\Plain paragraph.
        \\
        \\*Emphasized* paragraph.
        \\
        \\Another plain one.
    );
    defer doc.deinit(alloc);

    const q = doc.get();
    var em_paras = try q.paragraphsWithInlines(alloc, .emphasis);
    defer em_paras.deinit(alloc);
    try tst.expectEqual(@as(usize, 1), em_paras.items.len);
}

test "query: paragraphsWithInlines code_span" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc,
        \\Use `code` here.
        \\
        \\And `more code` too.
        \\
        \\No code at all.
    );
    defer doc.deinit(alloc);

    const q = doc.get();
    var code_paras = try q.paragraphsWithInlines(alloc, .code_span);
    defer code_paras.deinit(alloc);
    try tst.expectEqual(@as(usize, 2), code_paras.items.len);
}

test "query: count mixed document" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try parse(alloc,
        \\# Heading
        \\
        \\Paragraph.
        \\
        \\- item1
        \\- item2
        \\
        \\> blockquote
        \\
        \\---
        \\
        \\```
        \\code
        \\```
    );
    defer doc.deinit(alloc);

    const q = doc.get();
    try tst.expectEqual(@as(usize, 1), q.count(.heading));
    try tst.expectEqual(@as(usize, 1), q.count(.paragraph));
    try tst.expectEqual(@as(usize, 1), q.count(.list));
    try tst.expectEqual(@as(usize, 1), q.count(.blockquote));
    try tst.expectEqual(@as(usize, 1), q.count(.thematic_break));
    try tst.expectEqual(@as(usize, 1), q.count(.fenced_code_block));
}
