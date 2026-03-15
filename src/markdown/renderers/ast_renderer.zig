//! AST tree renderer for the Markdown AST.
//!
//! Serialises an `AST.Document` into a human-readable tree diagram with
//! box-drawing characters (└── / ├── / │).  This renderer conforms to
//! the same `render(Allocator, AST.Document) ![]u8` interface as the
//! HTML renderer, so it can be used as a pluggable `Renderer` back-end.
const std = @import("std");
const Allocator = std.mem.Allocator;
const tst = std.testing;

const AST = @import("../ast.zig");
const Parser = @import("../parser.zig");

// ── Tree-drawing constants ────────────────────────────────────────────────────

const connector_last = "└── ";
const connector_mid = "├── ";
const prefix_last = "    ";
const prefix_mid = "│   ";

// ── Block renderer ────────────────────────────────────────────────────────────

fn renderBlock(writer: anytype, block: AST.Block, prefix: []const u8, is_last: bool, allocator: Allocator) !void {
    const conn: []const u8 = if (is_last) connector_last else connector_mid;
    const child_ext: []const u8 = if (is_last) prefix_last else prefix_mid;

    try writer.writeAll(prefix);
    try writer.writeAll(conn);

    switch (block) {
        .table => {},
        .paragraph => |para| {
            try writer.writeAll("Paragraph\n");
            const new_prefix = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, child_ext });
            defer allocator.free(new_prefix);
            for (para.children.items, 0..) |inl, j| {
                try renderInline(writer, inl, new_prefix, j == para.children.items.len - 1, allocator);
            }
        },
        .heading => |h| {
            try writer.print("Heading (level={d})\n", .{h.level});
            const new_prefix = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, child_ext });
            defer allocator.free(new_prefix);
            for (h.children.items, 0..) |inl, j| {
                try renderInline(writer, inl, new_prefix, j == h.children.items.len - 1, allocator);
            }
        },
        .code_block => |cb| {
            try writer.print("CodeBlock ({d} bytes)\n", .{cb.content.len});
        },
        .fenced_code_block => |fcb| {
            if (fcb.language) |lang| {
                try writer.print("FencedCodeBlock lang=\"{s}\" ({d} bytes)\n", .{ lang, fcb.content.len });
            } else {
                try writer.print("FencedCodeBlock ({d} bytes)\n", .{fcb.content.len});
            }
        },
        .blockquote => |bq| {
            try writer.writeAll("Blockquote\n");
            const new_prefix = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, child_ext });
            defer allocator.free(new_prefix);
            for (bq.children.items, 0..) |child, j| {
                try renderBlock(writer, child, new_prefix, j == bq.children.items.len - 1, allocator);
            }
        },
        .list => |lst| {
            const kind: []const u8 = if (lst.type == .ordered) "ordered" else "unordered";
            const tight_str: []const u8 = if (lst.tight) "tight" else "loose";
            if (lst.start) |start| {
                try writer.print("List ({s}, {s}, start={d})\n", .{ kind, tight_str, start });
            } else {
                try writer.print("List ({s}, {s})\n", .{ kind, tight_str });
            }
            const new_prefix = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, child_ext });
            defer allocator.free(new_prefix);
            for (lst.items.items, 0..) |item, j| {
                const last = j == lst.items.items.len - 1;
                const item_conn: []const u8 = if (last) connector_last else connector_mid;
                const item_ext: []const u8 = if (last) prefix_last else prefix_mid;
                try writer.writeAll(new_prefix);
                try writer.writeAll(item_conn);
                try writer.writeAll("ListItem\n");
                const item_prefix = try std.fmt.allocPrint(allocator, "{s}{s}", .{ new_prefix, item_ext });
                defer allocator.free(item_prefix);
                for (item.children.items, 0..) |child, k| {
                    try renderBlock(writer, child, item_prefix, k == item.children.items.len - 1, allocator);
                }
            }
        },
        .thematic_break => |tb| {
            try writer.print("ThematicBreak ('{c}')\n", .{tb.char});
        },
        .html_block => |hb| {
            try writer.print("HtmlBlock ({d} bytes)\n", .{hb.content.len});
        },
        .footnote_definition => |fd| {
            try writer.print("FootnoteDefinition [{s}]\n", .{fd.label});
            const new_prefix = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, child_ext });
            defer allocator.free(new_prefix);
            for (fd.children.items, 0..) |child, j| {
                try renderBlock(writer, child, new_prefix, j == fd.children.items.len - 1, allocator);
            }
        },
    }
}

// ── Inline renderer ───────────────────────────────────────────────────────────

fn renderInline(writer: anytype, inl: AST.Inline, prefix: []const u8, is_last: bool, allocator: Allocator) !void {
    const conn: []const u8 = if (is_last) connector_last else connector_mid;
    const child_ext: []const u8 = if (is_last) prefix_last else prefix_mid;

    try writer.writeAll(prefix);
    try writer.writeAll(conn);

    switch (inl) {
        .text => |t| {
            const max_len: usize = 60;
            if (t.content.len > max_len) {
                try writer.print("Text \"{s}...\"\n", .{t.content[0..max_len]});
            } else {
                try writer.print("Text \"{s}\"\n", .{t.content});
            }
        },
        .emphasis => |em| {
            try writer.print("Emphasis ('{c}')\n", .{em.marker});
            const new_prefix = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, child_ext });
            defer allocator.free(new_prefix);
            for (em.children.items, 0..) |child, j| {
                try renderInline(writer, child, new_prefix, j == em.children.items.len - 1, allocator);
            }
        },
        .strong => |s| {
            try writer.print("Strong ('{c}')\n", .{s.marker});
            const new_prefix = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, child_ext });
            defer allocator.free(new_prefix);
            for (s.children.items, 0..) |child, j| {
                try renderInline(writer, child, new_prefix, j == s.children.items.len - 1, allocator);
            }
        },
        .code_span => |cs| {
            try writer.print("CodeSpan \"{s}\"\n", .{cs.content});
        },
        .link => |lnk| {
            try writer.print("Link url=\"{s}\"\n", .{lnk.destination.url});
            const new_prefix = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, child_ext });
            defer allocator.free(new_prefix);
            for (lnk.children.items, 0..) |child, j| {
                try renderInline(writer, child, new_prefix, j == lnk.children.items.len - 1, allocator);
            }
        },
        .image => |img| {
            try writer.print("Image alt=\"{s}\" url=\"{s}\"\n", .{ img.alt_text, img.destination.url });
        },
        .autolink => |al| {
            try writer.print("Autolink \"{s}\"\n", .{al.url});
        },
        .footnote_reference => |fr| {
            try writer.print("FootnoteRef [{s}]\n", .{fr.label});
        },
        .hard_break => {
            try writer.writeAll("HardBreak\n");
        },
        .soft_break => {
            try writer.writeAll("SoftBreak\n");
        },
        .html_in_line => |hi| {
            try writer.print("HtmlInline \"{s}\"\n", .{hi.content});
        },
    }
}

// ── Top-level render ──────────────────────────────────────────────────────────

/// Render `doc` to an allocator-owned AST tree diagram byte slice.
///
/// The caller owns the returned memory and must free it when done.
/// Conforms to the `Renderer` interface: `fn render(Allocator, AST.Document) ![]u8`.
pub fn render(allocator: Allocator, doc: AST.Document) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("Document\n");
    for (doc.children.items, 0..) |block, i| {
        try renderBlock(&aw.writer, block, "", i == doc.children.items.len - 1, allocator);
    }
    return aw.toOwnedSlice();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn ok(s: []const u8, expected: []const u8) !void {
    const allocator = tst.allocator;
    var parser = Parser.init();
    defer parser.deinit(allocator);
    var res = try parser.parseMarkdown(allocator, s);
    defer res.deinit(allocator);
    const out = try render(allocator, res);
    defer allocator.free(out);
    try tst.expectEqualStrings(expected, out);
}

test "ast: heading" {
    try ok("# Heading",
        \\Document
        \\└── Heading (level=1)
        \\    └── Text "Heading"
        \\
    );
}

test "ast: paragraph with emphasis" {
    try ok("**bold** and *italic*",
        \\Document
        \\└── Paragraph
        \\    ├── Strong ('*')
        \\    │   └── Text "bold"
        \\    ├── Text " and "
        \\    └── Emphasis ('*')
        \\        └── Text "italic"
        \\
    );
}

test "ast: unordered list" {
    try ok("- a\n- b\n- c",
        \\Document
        \\└── List (unordered, tight)
        \\    ├── ListItem
        \\    │   └── Paragraph
        \\    │       └── Text "a"
        \\    ├── ListItem
        \\    │   └── Paragraph
        \\    │       └── Text "b"
        \\    └── ListItem
        \\        └── Paragraph
        \\            └── Text "c"
        \\
    );
}

test "ast: blockquote" {
    try ok("> quote",
        \\Document
        \\└── Blockquote
        \\    └── Paragraph
        \\        └── Text "quote"
        \\
    );
}

test "ast: link" {
    try ok("[text](https://example.com)",
        \\Document
        \\└── Paragraph
        \\    └── Link url="https://example.com"
        \\        └── Text "text"
        \\
    );
}

test "ast: image" {
    try ok("![alt](img.png)",
        \\Document
        \\└── Paragraph
        \\    └── Image alt="alt" url="img.png"
        \\
    );
}

test "ast: code block" {
    try ok("```zig\nconst x = 1;\n```",
        \\Document
        \\└── FencedCodeBlock lang="zig" (12 bytes)
        \\
    );
}

test "ast: thematic break" {
    try ok("---",
        \\Document
        \\└── ThematicBreak ('-')
        \\
    );
}

test "ast: autolink" {
    try ok("<https://example.com>",
        \\Document
        \\└── Paragraph
        \\    └── Autolink "https://example.com"
        \\
    );
}

test "ast: hard break" {
    try ok("line one  \nline two",
        \\Document
        \\└── Paragraph
        \\    ├── Text "line one"
        \\    ├── HardBreak
        \\    └── Text "line two"
        \\
    );
}

test "ast: multiple blocks" {
    try ok("# Title\n\nParagraph text.\n\n---",
        \\Document
        \\├── Heading (level=1)
        \\│   └── Text "Title"
        \\├── Paragraph
        \\│   └── Text "Paragraph text."
        \\└── ThematicBreak ('-')
        \\
    );
}

test "ast: render via Renderer interface" {
    const root = @import("../../root.zig");
    const allocator = tst.allocator;

    var parser = Parser.init();
    var doc = try parser.parseMarkdown(allocator, "# Hello");
    defer doc.deinit(allocator);

    const ast_renderer = root.ASTRenderer;
    const output = try ast_renderer.render(allocator, doc);
    defer allocator.free(output);

    try tst.expect(std.mem.indexOf(u8, output, "Document") != null);
    try tst.expect(std.mem.indexOf(u8, output, "Heading (level=1)") != null);
    try tst.expect(std.mem.indexOf(u8, output, "Text \"Hello\"") != null);
}
