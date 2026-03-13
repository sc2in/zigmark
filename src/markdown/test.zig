const std = @import("std");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;
const tst = std.testing;
const math = std.math;

const AST = @import("ast.zig");
const Parser = @import("parser.zig");
const parsers = Parser.parsers;

// ── Tests ─────────────────────────────────────────────────────────────────────

test "basic character parsers" {
    const allocator = tst.allocator;
    const hr = try parsers.hash.parse(allocator, "#hello");
    try tst.expect(hr.value == .ok);
    try tst.expectEqual(@as(u8, '#'), hr.value.ok);
    try tst.expectEqual(@as(usize, 1), hr.index);
}

test "mecha atx_heading parser" {
    const allocator = tst.allocator;
    const result = try parsers.atx_heading.parse(allocator, "## Hello World");
    try tst.expect(result.value == .ok);
    try tst.expectEqual(@as(u8, 2), result.value.ok.level);
    try tst.expectEqualStrings("Hello World", result.value.ok.content);
}

test "mecha bullet_list_item parser" {
    const allocator = tst.allocator;
    const result = try parsers.bullet_list_item.parse(allocator, "- item content");
    try tst.expect(result.value == .ok);
    try tst.expectEqual(@as(u8, '-'), result.value.ok.marker);
    try tst.expectEqualStrings("item content", result.value.ok.content);
}

test "mecha ordered_list_item parser" {
    const allocator = tst.allocator;
    const result = try parsers.ordered_list_item.parse(allocator, "3. third item");
    try tst.expect(result.value == .ok);
    try tst.expectEqual(@as(u32, 3), result.value.ok.num);
    try tst.expectEqual(@as(u8, '.'), result.value.ok.delimiter);
    try tst.expectEqualStrings("third item", result.value.ok.content);
}

fn ok(s: []const u8) !void {
    const alloc = tst.allocator;
    var p = Parser.init();
    defer p.deinit(alloc);
    var res = try p.parseMarkdown(alloc, s);
    defer res.deinit(alloc);
}

test "heading" {
    try ok("# Heading\n");
    try ok("## Level 2\n");
    try ok("### Level 3\n");
}

test "setext heading" {
    const alloc = tst.allocator;
    var p = Parser.init();
    {
        var doc = try p.parseMarkdown(alloc, "Heading\n=======\n");
        defer doc.deinit(alloc);
        try tst.expect(doc.children.items.len == 1);
        try tst.expect(doc.children.items[0] == .heading);
        try tst.expectEqual(@as(u8, 1), doc.children.items[0].heading.level);
    }
    {
        var doc = try p.parseMarkdown(alloc, "Heading\n-------\n");
        defer doc.deinit(alloc);
        try tst.expect(doc.children.items[0] == .heading);
        try tst.expectEqual(@as(u8, 2), doc.children.items[0].heading.level);
    }
}

test "thematic break" {
    const alloc = tst.allocator;
    var p = Parser.init();
    var doc = try p.parseMarkdown(alloc, "---\n");
    defer doc.deinit(alloc);
    try tst.expectEqual(1, doc.children.items.len);
    try tst.expectEqual(.thematic_break, std.meta.activeTag(doc.children.items[0]));
}

test "paragraph" {
    try ok("Simple paragraph\n");
    try ok("Multiple words\n");
}

test "multi-line paragraph" {
    const alloc = tst.allocator;
    var p = Parser.init();
    var doc = try p.parseMarkdown(alloc, "line one\nline two\n");
    defer doc.deinit(alloc);
    try tst.expect(doc.children.items.len == 1);
    try tst.expect(doc.children.items[0] == .paragraph);
    const children = doc.children.items[0].paragraph.children.items;
    try tst.expect(children.len == 3);
    try tst.expect(children[1] == .soft_break);
}

test "indented code block" {
    const alloc = tst.allocator;
    var p = Parser.init();
    var doc = try p.parseMarkdown(alloc, "    code here\n");
    defer doc.deinit(alloc);
    try tst.expect(doc.children.items.len == 1);
    try tst.expect(doc.children.items[0] == .code_block);
}

test "fenced code block" {
    try ok("```\ncode\n```\n");
    try ok("~~~zig\ncode\n~~~\n");
    {
        const alloc = tst.allocator;
        var p = Parser.init();
        var doc = try p.parseMarkdown(alloc, "```zig\nconst x = 1;\n```\n");
        defer doc.deinit(alloc);
        try tst.expect(doc.children.items.len == 1);
        try tst.expect(doc.children.items[0] == .fenced_code_block);
        try tst.expectEqualStrings("zig", doc.children.items[0].fenced_code_block.language.?);
    }
}

test "list grouping" {
    const alloc = tst.allocator;
    var p = Parser.init();
    var doc = try p.parseMarkdown(alloc, "- item1\n- item2\n- item3\n");
    defer doc.deinit(alloc);
    try tst.expect(doc.children.items.len == 1);
    try tst.expect(doc.children.items[0] == .list);
    try tst.expectEqual(@as(usize, 3), doc.children.items[0].list.items.items.len);
    try tst.expect(doc.children.items[0].list.tight);
}

test "loose list" {
    const alloc = tst.allocator;
    var p = Parser.init();
    var doc = try p.parseMarkdown(alloc, "- item1\n\n- item2\n");
    defer doc.deinit(alloc);
    try tst.expect(doc.children.items[0] == .list);
    try tst.expect(!doc.children.items[0].list.tight);
}

test "ordered list" {
    const alloc = tst.allocator;
    var p = Parser.init();
    var doc = try p.parseMarkdown(alloc, "1. first\n2. second\n");
    defer doc.deinit(alloc);
    try tst.expect(doc.children.items.len == 1);
    try tst.expect(doc.children.items[0] == .list);
    try tst.expectEqual(AST.ListType.ordered, doc.children.items[0].list.type);
    try tst.expectEqual(@as(usize, 2), doc.children.items[0].list.items.items.len);
}

test "code block compat" {
    try ok("``````\n");
}

test "list compat" {
    try ok("- item\n");
    try ok("* item\n");
    try ok("1. item\n");
}

test "emphasis and strong" {
    try ok("*italic*\n");
    try ok("**bold**\n");
}

test "link" {
    try ok("[text](url)\n");
    try ok("[text](url \"title\")\n");
}

test "footnote" {
    try ok("[^1]\n[^1]: content\n");
}

test "backslash escape" {
    const alloc = tst.allocator;
    var p = Parser.init();
    var doc = try p.parseMarkdown(alloc, "\\*not emphasis\\*\n");
    defer doc.deinit(alloc);
    try tst.expect(doc.children.items.len == 1);
    try tst.expect(doc.children.items[0] == .paragraph);
}

test "code span" {
    const alloc = tst.allocator;
    var p = Parser.init();
    var doc = try p.parseMarkdown(alloc, "Use `code` here\n");
    defer doc.deinit(alloc);
    const para = doc.children.items[0].paragraph;
    var found_code = false;
    for (para.children.items) |item| if (item == .code_span) {
        found_code = true;
    };
    try tst.expect(found_code);
}

test "autolink" {
    const alloc = tst.allocator;
    var p = Parser.init();
    var doc = try p.parseMarkdown(alloc, "<https://example.com>\n");
    defer doc.deinit(alloc);
    const para = doc.children.items[0].paragraph;
    try tst.expect(para.children.items[0] == .autolink);
    try tst.expect(!para.children.items[0].autolink.is_email);
}

test "image" {
    const alloc = tst.allocator;
    try ok("![alt](image.png)\n");
    var p = Parser.init();
    var doc = try p.parseMarkdown(alloc, "![alt text](img.png)\n");
    defer doc.deinit(alloc);
    const para = doc.children.items[0].paragraph;
    try tst.expect(para.children.items[0] == .image);
    try tst.expectEqualStrings("alt text", para.children.items[0].image.alt_text);
}
