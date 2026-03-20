const std = @import("std");
const tst = std.testing;

const AST = @import("ast.zig");
const Parser = @import("parser.zig");
const markdown_renderer = @import("renderers/markdown.zig");

fn parse(allocator: std.mem.Allocator, input: []const u8) !AST.Document {
    var p = Parser.init();
    return p.parseMarkdown(allocator, input);
}

// ── Document.Mutate: appendBlock ─────────────────────────────────────────────

test "mutate: appendBlock increases length" {
    const alloc = tst.allocator;

    var doc = try parse(alloc, "# First\n\nParagraph.");
    defer doc.deinit(alloc);
    try tst.expectEqual(@as(usize, 2), doc.children.items.len);

    const new_heading = try AST.Heading.fromText(alloc, 2, "Second");
    try doc.edit().appendBlock(alloc, .{ .heading = new_heading });

    try tst.expectEqual(@as(usize, 3), doc.children.items.len);
    try tst.expect(doc.children.items[2] == .heading);
    try tst.expectEqual(@as(u8, 2), doc.children.items[2].heading.level);
}

test "mutate: appendBlock to empty document" {
    const alloc = tst.allocator;

    var doc = AST.Document.init(alloc);
    defer doc.deinit(alloc);
    try tst.expectEqual(@as(usize, 0), doc.children.items.len);

    const para = try AST.Paragraph.fromText(alloc, "Hello");
    try doc.edit().appendBlock(alloc, .{ .paragraph = para });

    try tst.expectEqual(@as(usize, 1), doc.children.items.len);
    try tst.expect(doc.children.items[0] == .paragraph);
}

// ── Document.Mutate: insertBlock ─────────────────────────────────────────────

test "mutate: insertBlock at index 0 prepends" {
    const alloc = tst.allocator;

    var doc = try parse(alloc, "# Original\n\nParagraph.");
    defer doc.deinit(alloc);

    const new_heading = try AST.Heading.fromText(alloc, 1, "Prepended");
    try doc.edit().insertBlock(alloc, 0, .{ .heading = new_heading });

    try tst.expectEqual(@as(usize, 3), doc.children.items.len);
    try tst.expect(doc.children.items[0] == .heading);
    try tst.expectEqualStrings("Prepended", doc.children.items[0].heading.children.items[0].text.content);
}

test "mutate: insertBlock in the middle preserves order" {
    const alloc = tst.allocator;

    var doc = try parse(alloc, "# A\n\n# C");
    defer doc.deinit(alloc);
    try tst.expectEqual(@as(usize, 2), doc.children.items.len);

    const b_heading = try AST.Heading.fromText(alloc, 1, "B");
    try doc.edit().insertBlock(alloc, 1, .{ .heading = b_heading });

    try tst.expectEqual(@as(usize, 3), doc.children.items.len);
    try tst.expectEqualStrings("B", doc.children.items[1].heading.children.items[0].text.content);
}

// ── Document.Mutate: removeBlock ─────────────────────────────────────────────

test "mutate: removeBlock decreases length" {
    const alloc = tst.allocator;

    var doc = try parse(alloc, "# Title\n\nParagraph.\n\n---");
    defer doc.deinit(alloc);
    try tst.expectEqual(@as(usize, 3), doc.children.items.len);

    doc.edit().removeBlock(alloc, 1); // remove the paragraph

    try tst.expectEqual(@as(usize, 2), doc.children.items.len);
    try tst.expect(doc.children.items[0] == .heading);
    try tst.expect(doc.children.items[1] == .thematic_break);
}

test "mutate: removeBlock last element" {
    const alloc = tst.allocator;

    var doc = try parse(alloc, "# Only");
    defer doc.deinit(alloc);

    doc.edit().removeBlock(alloc, 0);
    try tst.expectEqual(@as(usize, 0), doc.children.items.len);
}

// ── Document.Mutate: replaceBlock ─────────────────────────────────────────────

test "mutate: replaceBlock swaps type and content" {
    const alloc = tst.allocator;

    var doc = try parse(alloc, "# Old Title\n\nParagraph.");
    defer doc.deinit(alloc);

    const new_h = try AST.Heading.fromText(alloc, 2, "New Title");
    doc.edit().replaceBlock(alloc, 0, .{ .heading = new_h });

    try tst.expect(doc.children.items[0] == .heading);
    try tst.expectEqual(@as(u8, 2), doc.children.items[0].heading.level);
    try tst.expectEqualStrings("New Title", doc.children.items[0].heading.children.items[0].text.content);
}

test "mutate: replaceBlock with different block type" {
    const alloc = tst.allocator;

    var doc = try parse(alloc, "# Heading");
    defer doc.deinit(alloc);
    try tst.expect(doc.children.items[0] == .heading);

    const para = try AST.Paragraph.fromText(alloc, "Replaced with paragraph");
    doc.edit().replaceBlock(alloc, 0, .{ .paragraph = para });

    try tst.expect(doc.children.items[0] == .paragraph);
}

// ── Heading.fromText ─────────────────────────────────────────────────────────

test "Heading.fromText: level and content" {
    const alloc = tst.allocator;

    var h = try AST.Heading.fromText(alloc, 3, "Hello World");
    defer h.deinit(alloc);

    try tst.expectEqual(@as(u8, 3), h.level);
    try tst.expectEqual(@as(usize, 1), h.children.items.len);
    try tst.expect(h.children.items[0] == .text);
    try tst.expectEqualStrings("Hello World", h.children.items[0].text.content);
}

test "Heading.fromText: empty string" {
    const alloc = tst.allocator;

    var h = try AST.Heading.fromText(alloc, 1, "");
    defer h.deinit(alloc);

    try tst.expectEqual(@as(usize, 1), h.children.items.len);
    try tst.expectEqualStrings("", h.children.items[0].text.content);
}

// ── Paragraph.fromText ───────────────────────────────────────────────────────

test "Paragraph.fromText: content" {
    const alloc = tst.allocator;

    var p = try AST.Paragraph.fromText(alloc, "Some text.");
    defer p.deinit(alloc);

    try tst.expectEqual(@as(usize, 1), p.children.items.len);
    try tst.expect(p.children.items[0] == .text);
    try tst.expectEqualStrings("Some text.", p.children.items[0].text.content);
}

// ── TableCell.fromText ───────────────────────────────────────────────────────

test "TableCell.fromText: content" {
    const alloc = tst.allocator;

    var cell = try AST.TableCell.fromText(alloc, "Cell value");
    defer cell.deinit(alloc);

    try tst.expectEqual(@as(usize, 1), cell.children.items.len);
    try tst.expect(cell.children.items[0] == .text);
    try tst.expectEqualStrings("Cell value", cell.children.items[0].text.content);
}

// ── TableRow.fromStrings ─────────────────────────────────────────────────────

test "TableRow.fromStrings: cell count and values" {
    const alloc = tst.allocator;

    var row = try AST.TableRow.fromStrings(alloc, &.{ "A", "B", "C" });
    defer row.deinit(alloc);

    try tst.expectEqual(@as(usize, 3), row.cells.items.len);
    try tst.expectEqualStrings("A", row.cells.items[0].children.items[0].text.content);
    try tst.expectEqualStrings("B", row.cells.items[1].children.items[0].text.content);
    try tst.expectEqualStrings("C", row.cells.items[2].children.items[0].text.content);
}

test "TableRow.fromStrings: empty slice" {
    const alloc = tst.allocator;

    var row = try AST.TableRow.fromStrings(alloc, &.{});
    defer row.deinit(alloc);

    try tst.expectEqual(@as(usize, 0), row.cells.items.len);
}

// ── Round-trip: build document programmatically and render ───────────────────

test "round-trip: build GFM table document and render to Markdown" {
    const alloc = tst.allocator;

    // Build a document with a GFM table from scratch.
    var doc = AST.Document.init(alloc);
    defer doc.deinit(alloc);

    var table = AST.Table.init(alloc);
    errdefer table.deinit(alloc);

    try table.alignments.append(alloc, .left);
    try table.alignments.append(alloc, .right);

    table.header.deinit(alloc);
    table.header = try AST.TableRow.fromStrings(alloc, &.{ "Name", "Score" });

    const row1 = try AST.TableRow.fromStrings(alloc, &.{ "Alice", "100" });
    try table.body.append(alloc, row1);
    const row2 = try AST.TableRow.fromStrings(alloc, &.{ "Bob", "85" });
    try table.body.append(alloc, row2);

    try doc.edit().appendBlock(alloc, .{ .table = table });

    const rendered = try markdown_renderer.render(alloc, doc);
    defer alloc.free(rendered);

    try tst.expect(std.mem.indexOf(u8, rendered, "| Name") != null);
    try tst.expect(std.mem.indexOf(u8, rendered, "Alice") != null);
    try tst.expect(std.mem.indexOf(u8, rendered, "Bob") != null);
    try tst.expect(std.mem.indexOf(u8, rendered, "100") != null);
    try tst.expect(std.mem.indexOf(u8, rendered, "85") != null);
}

test "round-trip: build document with heading and paragraph" {
    const alloc = tst.allocator;

    var doc = AST.Document.init(alloc);
    defer doc.deinit(alloc);
    const m = doc.edit();

    const h = try AST.Heading.fromText(alloc, 1, "My Title");
    try m.appendBlock(alloc, .{ .heading = h });
    const p = try AST.Paragraph.fromText(alloc, "Hello, world.");
    try m.appendBlock(alloc, .{ .paragraph = p });

    const rendered = try markdown_renderer.render(alloc, doc);
    defer alloc.free(rendered);

    try tst.expect(std.mem.indexOf(u8, rendered, "# My Title") != null);
    try tst.expect(std.mem.indexOf(u8, rendered, "Hello, world.") != null);
}
