const mecha = @import("mecha");
const std = @import("std");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;
const tst = std.testing;
const math = std.math;

const AST = struct {
    const Document = struct {
        blocks: []BlockNode,
        footnote_defs: []FootnoteDef,

        const parser = mecha.combine(.{
            ws.opt().discard(),
            block_parser.many(.{ .collect = true }),
            footnote_def_parser.many(.{ .collect = true }),
        }).convert(toDocument);

        fn toDocument(allocator: Allocator, result: anytype) !Document {
            _ = allocator;
            return .{
                .blocks = result[0],
                .footnote_defs = result[1],
            };
        }
        pub fn deinit(self: Document, alloc: Allocator) void {
            for (self.blocks) |b|
                b.deinit(alloc);

            for (self.footnote_defs) |f|
                f.deinit(alloc);
        }
    };

    const BlockNode = union(enum) {
        heading: Heading,
        paragraph: Paragraph,
        thematic_break: ThematicBreak,
        code_block: CodeBlock,
        html_block: HtmlBlock,
        blockquote: Blockquote,
        list: List,

        pub fn deinit(self: BlockNode, alloc: Allocator) void {
            switch (self) {
                inline else => |v| v.deinit(alloc),
            }
        }
    };

    const Heading = struct {
        level: u8,
        content: []InlineNode,

        const parser = mecha.combine(.{
            mecha.utf8.char('#').many(.{ .min = 1, .max = 6, .collect = true }),
            ws,
            mecha.ref(inlineRef).many(.{ .collect = true }),
            newline,
        }).convert(toHeading);

        fn toHeading(allocator: Allocator, result: anytype) !BlockNode {
            _ = allocator;
            return .{ .heading = .{
                .level = @intCast(result[0].len),
                .content = result[1],
            } };
        }
        pub fn deinit(self: Heading, alloc: Allocator) void {
            for (self.content) |n|
                n.deinit(alloc);
        }
    };

    const Paragraph = struct {
        content: []InlineNode,

        const parser = mecha.combine(.{
            mecha.ref(inlineRef).many(.{ .min = 1, .collect = true }),
            newline,
        }).convert(toParagraph);

        fn toParagraph(allocator: Allocator, result: anytype) !BlockNode {
            _ = allocator;
            return .{ .paragraph = .{
                .content = result,
            } };
        }
        pub fn deinit(self: Paragraph, alloc: Allocator) void {
            for (self.content) |n|
                n.deinit(alloc);
        }
    };

    const Text = struct {
        content: []u21,

        // Match text that isn't a special inline character
        // Stop at: newline, *, _, `, [, !, <, \, or space at line end
        const text_char = mecha.utf8.range(0x20, 0x7E)
            .discard()
            .toResult(mecha.asStr)
            .map(mecha.toStruct(struct { c: u21 }))
            .convert(filterSpecialChars);

        fn filterSpecialChars(allocator: Allocator, chr: struct { c: u21 }) !?struct { c: u21 } {
            _ = allocator;
            // Reject special inline syntax characters
            return switch (chr.c) {
                '*', '_', '`', '[', '!', '<', '\\', '\n', '\r' => null,
                else => chr,
            };
        }

        const parser = mecha.utf8.range(0x21, 0x7E)
            .many(.{ .min = 1, .collect = true })
            .convert(toText);

        fn toText(allocator: Allocator, content: []u21) !InlineNode {
            _ = allocator;
            return .{ .text = .{ .content = content } };
        }
        pub fn deinit(self: Text, alloc: Allocator) void {
            alloc.free(self.content);
        }
    };

    const Emphasis = struct {
        content: []InlineNode,

        const parser_asterisk = mecha.combine(.{
            mecha.utf8.char('*').discard(),
            mecha.ref(inlineRef).many(.{ .min = 1, .collect = true }),
            mecha.utf8.char('*').discard(),
        });

        const parser_underscore = mecha.combine(.{
            mecha.utf8.char('_').discard(),
            mecha.ref(inlineRef).many(.{ .min = 1, .collect = true }),
            mecha.utf8.char('_').discard(),
        });

        const parser = mecha.oneOf(.{
            parser_asterisk,
            parser_underscore,
        }).convert(toEmphasis);

        fn toEmphasis(allocator: Allocator, content: []InlineNode) !InlineNode {
            _ = allocator;
            return .{ .emphasis = .{ .content = content } };
        }
        pub fn deinit(self: Emphasis, alloc: Allocator) void {
            for (self.content) |n|
                n.deinit(alloc);
        }
    };

    const Strong = struct {
        content: []InlineNode,

        const parser_asterisk = mecha.combine(.{
            mecha.string("**").discard(),
            mecha.ref(inlineRef).many(.{ .min = 1, .collect = true }),
            mecha.string("**").discard(),
        });

        const parser_underscore = mecha.combine(.{
            mecha.string("__").discard(),
            mecha.ref(inlineRef).many(.{ .min = 1, .collect = true }),
            mecha.string("__").discard(),
        });

        const parser = mecha.oneOf(.{
            parser_asterisk,
            parser_underscore,
        }).convert(toStrong);

        fn toStrong(allocator: Allocator, content: []InlineNode) !InlineNode {
            _ = allocator;
            return .{ .strong = .{ .content = content } };
        }
        pub fn deinit(self: Strong, alloc: Allocator) void {
            for (self.content) |n|
                n.deinit(alloc);
        }
    };

    const InlineNode = union(enum) {
        text: Text,
        emphasis: Emphasis,
        strong: Strong,
        code_span: CodeSpan,
        link: Link,
        image: Image,
        html_inline: HtmlInline,
        hard_break: HardBreak,
        soft_break: SoftBreak,
        footnote_ref: FootnoteRef,

        pub fn deinit(self: InlineNode, alloc: Allocator) void {
            switch (self) {
                inline else => |v| v.deinit(alloc),
            }
        }
    };

    const ThematicBreak = struct {
        const parser_dash = mecha.utf8.char('-')
            .many(.{ .min = 3, .collect = false });

        const parser_asterisk = mecha.utf8.char('*')
            .many(.{ .min = 3, .collect = false });

        const parser_underscore = mecha.utf8.char('_')
            .many(.{ .min = 3, .collect = false });

        const parser = mecha.combine(.{
            mecha.oneOf(.{
                parser_dash,
                parser_asterisk,
                parser_underscore,
            }).discard(),
            newline,
        }).convert(toThematicBreak);

        fn toThematicBreak(allocator: Allocator, _: anytype) !BlockNode {
            _ = allocator;
            return .{ .thematic_break = .{} };
        }
        pub fn deinit(_: ThematicBreak, _: Allocator) void {}
    };

    const CodeBlock = struct {
        info_string: ?[]u21,
        content: []u21,
        is_fenced: bool,

        const fence_backtick = mecha.utf8.char('`')
            .many(.{ .min = 3, .collect = false });

        const fence_tilde = mecha.utf8.char('~')
            .many(.{ .min = 3, .collect = false });

        const fence = mecha.oneOf(.{
            fence_backtick,
            fence_tilde,
        }).discard();

        const info_string_parser = mecha.utf8.range('a', 'z')
            .many(.{ .collect = true })
            .opt();

        const content_parser = mecha.utf8.range(0x20, 0x7E)
            .many(.{ .collect = true });

        const parser = mecha.combine(.{
            fence,
            info_string_parser,
            newline.discard(),
            content_parser,
            newline.discard(),
            fence,
        }).convert(toCodeBlock);

        fn toCodeBlock(allocator: Allocator, result: anytype) !BlockNode {
            _ = allocator;
            return .{ .code_block = .{
                .info_string = result[0],
                .content = result[1],
                .is_fenced = true,
            } };
        }
        pub fn deinit(self: CodeBlock, alloc: Allocator) void {
            alloc.free(self.content);
            if (self.info_string) |i| alloc.free(i);
        }
    };

    const HtmlBlock = struct {
        content: []u21,
        block_type: u8,

        const parser = mecha.combine(.{
            mecha.utf8.char('<').discard(),
            mecha.utf8.range('a', 'z')
                .many(.{ .min = 1, .collect = true }),
            mecha.utf8.char('>').discard(),
            mecha.utf8.range(0x20, 0x7E)
                .many(.{ .collect = true }),
            mecha.string("</").discard(),
            mecha.utf8.range('a', 'z')
                .many(.{ .min = 1, .collect = false }),
            mecha.utf8.char('>').discard(),
            newline,
        }).convert(toHtmlBlock);

        fn toHtmlBlock(allocator: Allocator, result: anytype) !BlockNode {
            _ = allocator;
            return .{ .html_block = .{
                .content = result[1],
                .block_type = 1,
            } };
        }
        pub fn deinit(self: HtmlBlock, alloc: Allocator) void {
            alloc.free(self.content);
        }
    };

    const Blockquote = struct {
        blocks: []BlockNode,

        const parser = mecha.combine(.{
            mecha.utf8.char('>').discard(),
            ws,
            mecha.ref(blockRef).many(.{ .min = 1, .collect = true }),
        }).convert(toBlockquote);

        fn toBlockquote(allocator: Allocator, result: anytype) !BlockNode {
            _ = allocator;
            return .{ .blockquote = .{
                .blocks = result,
            } };
        }
        pub fn deinit(self: Blockquote, alloc: Allocator) void {
            for (self.blocks) |b| b.deinit(alloc);
        }
    };

    const List = struct {
        items: []ListItem,
        marker_type: MarkerType,
        tight: bool,

        const parser = ListItem.parser
            .many(.{ .min = 1, .collect = true })
            .convert(toList);

        fn toList(allocator: Allocator, items: []ListItem) !BlockNode {
            _ = allocator;
            return .{ .list = .{
                .items = items,
                .marker_type = .bullet,
                .tight = true,
            } };
        }
        pub fn deinit(self: List, alloc: Allocator) void {
            for (self.items) |i| i.deinit(alloc);
        }
    };

    const ListItem = struct {
        blocks: []BlockNode,

        const bullet_marker = mecha.oneOf(.{
            mecha.utf8.char('-'),
            mecha.utf8.char('*'),
            mecha.utf8.char('+'),
        }).discard();

        const ordered_marker = mecha.combine(.{
            mecha.utf8.range('0', '9')
                .many(.{ .min = 1, .collect = false }),
            mecha.utf8.char('.'),
        }).discard();

        const marker = mecha.oneOf(.{
            bullet_marker,
            ordered_marker,
        });

        const parser = mecha.combine(.{
            marker.discard(),
            ws,
            mecha.ref(blockRef).many(.{ .min = 1, .collect = true }),
        }).convert(toListItem);

        fn toListItem(allocator: Allocator, result: anytype) !ListItem {
            _ = allocator;
            return .{
                .blocks = result,
            };
        }
        pub fn deinit(self: ListItem, alloc: Allocator) void {
            for (self.blocks) |b| b.deinit(alloc);
        }
    };

    const MarkerType = enum {
        bullet,
        ordered,
    };

    const CodeSpan = struct {
        content: []u21,

        const parser = mecha.combine(.{
            mecha.utf8.char('`').discard(),
            mecha.utf8.range(0x20, 0x7E)
                .many(.{ .min = 1, .collect = true }),
            mecha.utf8.char('`').discard(),
        }).convert(toCodeSpan);

        fn toCodeSpan(allocator: Allocator, content: []u21) !InlineNode {
            _ = allocator;
            return .{ .code_span = .{ .content = content } };
        }

        pub fn deinit(self: CodeSpan, alloc: Allocator) void {
            alloc.free(self.content);
        }
    };

    const Link = struct {
        text: []InlineNode,
        destination: []u21,
        title: ?[]u21,

        const url_parser = mecha.utf8.range(0x21, 0x7E)
            .many(.{ .min = 1, .collect = true });

        const title_parser = mecha.combine(.{
            ws,
            mecha.utf8.char('"').discard(),
            mecha.utf8.range(0x20, 0x7E)
                .many(.{ .collect = true }),
            mecha.utf8.char('"').discard(),
        }).convert(extractTitle);

        fn extractTitle(allocator: Allocator, result: anytype) ![]u21 {
            _ = allocator;
            return result;
        }

        const parser = mecha.combine(.{
            mecha.utf8.char('[').discard(),
            mecha.ref(inlineRef).many(.{ .min = 1, .collect = true }),
            mecha.utf8.char(']').discard(),
            mecha.utf8.char('(').discard(),
            url_parser,
            title_parser.opt(),
            mecha.utf8.char(')').discard(),
        }).convert(toLink);

        fn toLink(allocator: Allocator, result: anytype) !InlineNode {
            _ = allocator;
            return .{ .link = .{
                .text = result[0],
                .destination = result[1],
                .title = result[2],
            } };
        }

        pub fn deinit(self: Link, alloc: Allocator) void {
            for (self.text) |t| t.deinit(alloc);
            alloc.free(self.destination);
            if (self.title) |t| alloc.free(t);
        }
    };

    const HardBreak = struct {
        const parser_spaces = mecha.combine(.{
            mecha.utf8.char(' ').discard(),
            mecha.utf8.char(' ').discard(),
            newline.discard(),
        });

        const parser_backslash = mecha.combine(.{
            mecha.utf8.char('\\').discard(),
            newline.discard(),
        });

        const parser = mecha.oneOf(.{
            parser_spaces,
            parser_backslash,
        }).convert(toHardBreak);

        fn toHardBreak(allocator: Allocator, _: anytype) !InlineNode {
            _ = allocator;
            return .{ .hard_break = .{} };
        }
        pub fn deinit(_: HardBreak, _: Allocator) void {}
    };

    const HtmlInline = struct {
        content: []u21,

        const parser = mecha.combine(.{
            mecha.utf8.char('<').discard(),
            mecha.utf8.range('a', 'z')
                .many(.{ .min = 1, .collect = true }),
            mecha.utf8.char('>').discard(),
        }).convert(toHtmlInline);

        fn toHtmlInline(allocator: Allocator, content: []u21) !InlineNode {
            _ = allocator;
            return .{ .html_inline = .{ .content = content } };
        }
        pub fn deinit(self: HtmlInline, alloc: Allocator) void {
            alloc.free(self.content);
        }
    };

    const Image = struct {
        alt_text: []InlineNode,
        destination: []u21,
        title: ?[]u21,

        const parser = mecha.combine(.{
            mecha.utf8.char('!').discard(),
            mecha.utf8.char('[').discard(),
            mecha.ref(inlineRef).many(.{ .collect = true }),
            mecha.utf8.char(']').discard(),
            mecha.utf8.char('(').discard(),
            Link.url_parser,
            Link.title_parser.opt(),
            mecha.utf8.char(')').discard(),
        }).convert(toImage);

        fn toImage(allocator: Allocator, result: anytype) !InlineNode {
            _ = allocator;
            return .{ .image = .{
                .alt_text = result[0],
                .destination = result[1],
                .title = result[2],
            } };
        }
        pub fn deinit(self: Image, alloc: Allocator) void {
            for (self.alt_text) |t| t.deinit(alloc);
            alloc.free(self.destination);
            if (self.title) |t| alloc.free(t);
        }
    };

    const SoftBreak = struct {
        const parser = newline.convert(toSoftBreak);

        fn toSoftBreak(allocator: Allocator, _: anytype) !InlineNode {
            _ = allocator;
            return .{ .soft_break = .{} };
        }
        pub fn deinit(_: SoftBreak, _: Allocator) void {}
    };

    const FootnoteRef = struct {
        label: []u21,

        const label_parser = mecha.utf8.range('a', 'z')
            .many(.{ .min = 1, .collect = true });

        const parser = mecha.combine(.{
            mecha.string("[^").discard(),
            label_parser,
            mecha.utf8.char(']').discard(),
        }).convert(toFootnoteRef);

        fn toFootnoteRef(allocator: Allocator, label: []u21) !InlineNode {
            _ = allocator;
            return .{ .footnote_ref = .{ .label = label } };
        }
        pub fn deinit(self: FootnoteRef, alloc: Allocator) void {
            alloc.free(self.label);
        }
    };

    const FootnoteDef = struct {
        label: []u21,
        blocks: []BlockNode,

        const parser = mecha.combine(.{
            mecha.string("[^").discard(),
            FootnoteRef.label_parser,
            mecha.string("]:").discard(),
            ws,
            mecha.ref(blockRef).many(.{ .min = 1, .collect = true }),
        }).convert(toFootnoteDef);

        fn toFootnoteDef(allocator: Allocator, result: anytype) !FootnoteDef {
            _ = allocator;
            return .{
                .label = result[0],
                .blocks = result[1],
            };
        }
        pub fn deinit(self: FootnoteDef, alloc: Allocator) void {
            for (self.blocks) |b| b.deinit(alloc);
            alloc.free(self.label);
        }
    };

    // Forward references
    fn blockRef() mecha.Parser(BlockNode) {
        return block_parser;
    }

    fn inlineRef() mecha.Parser(InlineNode) {
        return inline_parser;
    }

    // Main parsers
    const block_parser = mecha.oneOf(.{
        Heading.parser,
        CodeBlock.parser,
        ThematicBreak.parser,
        HtmlBlock.parser,
        Blockquote.parser,
        List.parser,
        Paragraph.parser,
    });

    const inline_parser = mecha.oneOf(.{
        Strong.parser,
        Emphasis.parser,
        CodeSpan.parser,
        Image.parser,
        Link.parser,
        FootnoteRef.parser,
        HtmlInline.parser,
        HardBreak.parser,
        SoftBreak.parser,
        Text.parser,
    });

    const footnote_def_parser = FootnoteDef.parser;

    // Single newline (not repeated)
    const newline = mecha.oneOf(.{
        mecha.string("\r\n").discard(),
        mecha.utf8.char('\n').discard(),
        mecha.utf8.char('\r').discard(),
    });

    const ws = mecha.oneOf(.{
        mecha.utf8.char(0x20).discard(),
        mecha.utf8.char(0x09).discard(),
    }).many(.{ .collect = false }).discard();

    const ASCII_PUNCT = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";
    const EmphasisDelimiter = enum { asterisk, underscore };
};

const markdown = AST.Document.parser;

fn ok(s: []const u8) !void {
    const res = try markdown.parse(tst.allocator, s);
    defer res.value.ok.deinit(tst.allocator);
    errdefer res.value.ok.deinit(tst.allocator);
    std.debug.print("{any}\n", .{res.value.ok});

    // errdefer res.value.err.deinit(tst.allocator);

    try tst.expectEqualStrings("", s[res.index..]);
}

fn err(pos: usize, s: []const u8) !void {
    try mecha.expectErr(AST.Document, pos, try markdown.parse(tst.allocator, s));
}

fn errNotAllParsed(s: []const u8) !void {
    const res = try markdown.parse(tst.allocator, s);
    defer res.value.ok.deinit(tst.allocator);
    errdefer res.value.ok.deinit(tst.allocator);

    try tst.expect(s[res.index..].len != 0);
}

test "heading test" {
    const res = try AST.Heading.parser.parse(tst.allocator,
        \\# Heading1
    );
    const doc = switch (res.value) {
        .err => {
            std.debug.print("Failed to parse doc at {}\n", .{res.index});
            return error.ParseError;
        },
        .ok => |o| o,
    };
    defer doc.deinit(tst.allocator);

    std.debug.print("{any}\n", .{doc});
}
// test "heading" {
//     try ok("# Heading\n");
//     try ok("## Level 2\n");
//     try ok("### Level 3\n");
// }

// test "paragraph" {
//     try ok("Simple paragraph\n");
//     try ok("Multiple words\n");
// }

// test "code block" {
//     try ok("``````\n");
//     try ok("``````\n");
// }

// test "list" {
//     try ok("- item\n");
//     try ok("* item\n");
//     try ok("1. item\n");
// }

// test "emphasis and strong" {
//     try ok("*italic*\n");
//     try ok("**bold**\n");
// }

// test "link" {
//     try ok("[text](url)\n");
//     try ok("[text](url \"title\")\n");
// }

// test "footnote" {
//     try ok("[^1]\n[^1]: content\n");
// }
