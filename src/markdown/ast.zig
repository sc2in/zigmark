const std = @import("std");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;
const tst = std.testing;
const math = std.math;
const mem = std.mem;

const mecha = @import("mecha");

const tokens = @import("tokens.zig");
const Token = tokens.Token;
const Range = tokens.Range;

/// Base node type for all AST elements
pub const Node = struct {
    range: ?Range = null,

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*node| if (@hasDecl(@TypeOf(node.*), "deinit")) {
                node.deinit(allocator);
            },
        }
    }
};

/// Document root node
pub const Document = struct {
    children: std.ArrayList(Block),

    pub fn init(allocator: std.mem.Allocator) Document {
        _ = allocator; // autofix
        return Document{
            .children = std.ArrayList(Block){},
        };
    }

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
    }
    /// Enhanced query system for easier node testing and traversal
    /// Supports jQuery-like selector syntax for AST navigation
    pub const Query = struct {
        document: *const Document,

        pub fn init(document: *const Document) Query {
            return Query{ .document = document };
        }

        /// Get all blocks of a specific type
        pub fn blocks(self: Query, allocator: std.mem.Allocator, block_type: std.meta.Tag(Block)) !std.ArrayList(*const Block) {
            var results = std.ArrayList(*const Block).init(allocator);

            for (self.document.children.items) |block| {
                if (std.meta.activeTag(block) == block_type) {
                    try results.append(block);
                }
            }

            return results;
        }

        /// Get headings by level
        pub fn headings(self: Query, allocator: std.mem.Allocator, level: ?u8) !std.ArrayList(*const Heading) {
            var results = std.ArrayList(*const Heading).init(allocator);

            for (self.document.children.items) |block| {
                if (block == .heading) {
                    if (level) |target_level| {
                        if (block.heading.level == target_level) {
                            try results.append(&block.heading);
                        }
                    } else {
                        try results.append(&block.heading);
                    }
                }
            }

            return results;
        }

        /// Get all paragraphs containing specific inline elements
        pub fn paragraphsWithInlines(self: Query, allocator: std.mem.Allocator, inline_type: std.meta.Tag(Inline)) !std.ArrayList(*const Paragraph) {
            var results = std.ArrayList(*const Paragraph).init(allocator);

            for (self.document.children.items) |*block| {
                if (block.* == .paragraph) {
                    for (block.paragraph.children.items) |*inline_elem| {
                        if (std.meta.activeTag(inline_elem.*) == inline_type) {
                            try results.append(&block.paragraph);
                            break;
                        }
                    }
                }
            }

            return results;
        }

        /// Get all links in the document
        pub fn links(self: Query, allocator: std.mem.Allocator) !std.ArrayList(*const Link) {
            var results = std.ArrayList(*const Link).init(allocator);

            for (self.document.children.items) |*block| {
                try self.collectLinksFromBlock(allocator, block, &results);
            }

            return results;
        }

        /// Get text content from a specific path (e.g., "heading[1].text")
        pub fn textAt(self: Query, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
            _ = allocator;

            // Simple path parsing for demonstration - can be extended
            if (mem.startsWith(u8, path, "heading[")) {
                const index_start = 8; // after "heading["
                const index_end = mem.indexOf(u8, path[index_start..], "]") orelse return null;
                const index = std.fmt.parseInt(usize, path[index_start .. index_start + index_end], 10) catch return null;

                if (index < self.document.children.items.len and
                    self.document.children.items[index] == .heading)
                {
                    const heading = &self.document.children.items[index].heading;
                    if (heading.children.items.len > 0 and heading.children.items[0] == .text) {
                        return heading.children.items[0].text.content;
                    }
                }
            }

            return null;
        }

        /// Count elements by type
        pub fn count(self: Query, element_type: anytype) usize {
            var counter: usize = 0;

            for (self.document.children.items) |*block| {
                counter += self.countInBlock(block, element_type);
            }

            return counter;
        }

        // Helper functions
        fn collectLinksFromBlock(self: Query, allocator: std.mem.Allocator, block: *const Block, results: *std.ArrayList(*const Link)) !void {
            switch (block.*) {
                .paragraph => |*p| {
                    for (p.children.items) |*inline_elem| {
                        if (inline_elem.* == .link) {
                            try results.append(&inline_elem.link);
                        }
                    }
                },
                .heading => |*h| {
                    for (h.children.items) |*inline_elem| {
                        if (inline_elem.* == .link) {
                            try results.append(&inline_elem.link);
                        }
                    }
                },
                .blockquote => |*bq| {
                    for (bq.children.items) |*child_block| {
                        try self.collectLinksFromBlock(allocator, child_block, results);
                    }
                },
                .list => |*l| {
                    for (l.items.items) |*item| {
                        for (item.children.items) |*child_block| {
                            try self.collectLinksFromBlock(allocator, child_block, results);
                        }
                    }
                },
                else => {},
            }
        }

        fn countInBlock(self: Query, block: *const Block, element_type: anytype) usize {
            _ = self;
            var counter: usize = 0;

            switch (@TypeOf(element_type)) {
                Heading => {
                    if (block.* == .heading) counter += 1;
                },
                Paragraph => {
                    if (block.* == .paragraph) counter += 1;
                },
                List => {
                    if (block.* == .list) counter += 1;
                },
                else => {},
            }

            return counter;
        }
    };

    /// Main dot notation interface
    pub fn get(self: *const Document) Query {
        return Query.init(self);
    }
};

/// Block-level elements
pub const Block = union(enum) {
    paragraph: Paragraph,
    heading: Heading,
    code_block: CodeBlock,
    fenced_code_block: FencedCodeBlock,
    blockquote: Blockquote,
    list: List,
    thematic_break: ThematicBreak,
    html_block: HtmlBlock,
    footnote_definition: FootnoteDefinition,

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*b| b.deinit(allocator),
        }
        // switch (self.*) {
        //     inline else => |*block| if (@hasDecl(@TypeOf(block.*), "deinit")) {
        //         block.deinit(allocator);
        //     } else std.debug.print("Warning: {s} has no deinit()\n", .{@tagName(self.*)}),
        // }
    }
};

/// Inline elements
pub const Inline = union(enum) {
    text: Text,
    emphasis: Emphasis,
    strong: Strong,
    code_span: CodeSpan,
    link: Link,
    image: Image,
    autolink: Autolink,
    footnote_reference: FootnoteReference,
    hard_break: HardBreak,
    soft_break: SoftBreak,
    html_in_line: HtmlInline,

    pub fn deinit(self: *Inline, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*in_line_elem| if (@hasDecl(@TypeOf(in_line_elem.*), "deinit")) {
                in_line_elem.deinit(allocator);
            },
        }
    }
};

/// Paragraph block
pub const Paragraph = struct {
    children: std.ArrayList(Inline),

    pub fn init(allocator: std.mem.Allocator) Paragraph {
        _ = allocator; // autofix
        return Paragraph{
            .children = std.ArrayList(Inline){},
        };
    }

    pub fn deinit(self: *Paragraph, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
    }
};

/// Heading block
pub const Heading = struct {
    level: u8,
    children: std.ArrayList(Inline),

    pub fn init(allocator: std.mem.Allocator, level: u8) Heading {
        _ = allocator; // autofix
        return Heading{
            .level = level,
            .children = std.ArrayList(Inline){},
        };
    }

    pub fn deinit(self: *Heading, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
    }
};

/// Indented code block
pub const CodeBlock = struct {
    content: []const u8,

    pub fn init(content: []const u8) CodeBlock {
        return CodeBlock{ .content = content };
    }
    pub fn deinit(_: CodeBlock, _: Allocator) void {}
};

/// Fenced code block
pub const FencedCodeBlock = struct {
    content: []const u8,
    language: ?[]const u8 = null,
    fence_char: u8,
    fence_length: usize,

    pub fn init(content: []const u8, language: ?[]const u8, fence_char: u8, fence_length: usize) FencedCodeBlock {
        return FencedCodeBlock{
            .content = content,
            .language = language,
            .fence_char = fence_char,
            .fence_length = fence_length,
        };
    }
    pub fn deinit(_: FencedCodeBlock, _: Allocator) void {}
};

/// Blockquote
pub const Blockquote = struct {
    children: std.ArrayList(Block),

    pub fn init(allocator: std.mem.Allocator) Blockquote {
        _ = allocator; // autofix
        return Blockquote{
            .children = std.ArrayList(Block){},
        };
    }

    pub fn deinit(self: *Blockquote, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
    }
};

/// List types
pub const ListType = enum {
    ordered,
    unordered,
};

/// List item
pub const ListItem = struct {
    children: std.ArrayList(Block),
    tight: bool = true,

    pub fn init(allocator: std.mem.Allocator) ListItem {
        _ = allocator; // autofix
        return ListItem{
            .children = std.ArrayList(Block){},
        };
    }

    pub fn deinit(self: *ListItem, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
    }
};

/// List
pub const List = struct {
    type: ListType,
    items: std.ArrayList(ListItem),
    tight: bool = true,
    start: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, list_type: ListType) List {
        _ = allocator; // autofix
        return List{
            .type = list_type,
            .items = std.ArrayList(ListItem){},
        };
    }

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| {
            item.deinit(allocator);
        }
        self.items.deinit(allocator);
    }
};

/// Thematic break (horizontal rule)
pub const ThematicBreak = struct {
    char: u8,

    pub fn init(char: u8) ThematicBreak {
        return ThematicBreak{ .char = char };
    }
    pub fn deinit(_: ThematicBreak, _: Allocator) void {}
};

/// HTML block
pub const HtmlBlock = struct {
    content: []const u8,

    pub fn init(content: []const u8) HtmlBlock {
        return HtmlBlock{ .content = content };
    }
    pub fn deinit(_: HtmlBlock, _: Allocator) void {}
};

/// Footnote definition
pub const FootnoteDefinition = struct {
    label: []const u8,
    children: std.ArrayList(Block),

    pub fn init(allocator: std.mem.Allocator, label: []const u8) FootnoteDefinition {
        _ = allocator; // autofix
        return FootnoteDefinition{
            .label = label,
            .children = std.ArrayList(Block){},
        };
    }

    pub fn deinit(self: *FootnoteDefinition, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
    }
};

/// Plain text
pub const Text = struct {
    content: []const u8,

    pub fn init(content: []const u8) Text {
        return Text{ .content = content };
    }
    pub fn deinit(_: Text, _: Allocator) void {}
};

/// Emphasis (italic)
pub const Emphasis = struct {
    children: std.ArrayList(Inline),
    marker: u8,

    pub fn init(allocator: std.mem.Allocator, marker: u8) Emphasis {
        _ = allocator; // autofix
        return Emphasis{
            .children = std.ArrayList(Inline){},
            .marker = marker,
        };
    }

    pub fn deinit(self: *Emphasis, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
    }
};

/// Strong emphasis (bold)
pub const Strong = struct {
    children: std.ArrayList(Inline),
    marker: u8,

    pub fn init(allocator: std.mem.Allocator, marker: u8) Strong {
        _ = allocator; // autofix
        return Strong{
            .children = std.ArrayList(Inline){},
            .marker = marker,
        };
    }

    pub fn deinit(self: *Strong, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
    }
};

/// Code span
pub const CodeSpan = struct {
    content: []const u8,

    pub fn init(content: []const u8) CodeSpan {
        return CodeSpan{ .content = content };
    }
};

/// Link destination and title
pub const LinkDestination = struct {
    url: []const u8,
    title: ?[]const u8 = null,

    pub fn init(url: []const u8, title: ?[]const u8) LinkDestination {
        return LinkDestination{
            .url = url,
            .title = title,
        };
    }
};

/// Link types
pub const LinkType = enum {
    in_line,
    reference,
    collapsed,
    shortcut,
};

/// Link
pub const Link = struct {
    children: std.ArrayList(Inline),
    destination: LinkDestination,
    link_type: LinkType,
    reference_label: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, destination: LinkDestination, link_type: LinkType) Link {
        _ = allocator; // autofix
        return Link{
            .children = std.ArrayList(Inline){},
            .destination = destination,
            .link_type = link_type,
        };
    }

    pub fn deinit(self: *Link, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
    }
};

/// Image
pub const Image = struct {
    alt_text: []const u8,
    destination: LinkDestination,
    link_type: LinkType,
    reference_label: ?[]const u8 = null,

    pub fn init(alt_text: []const u8, destination: LinkDestination, link_type: LinkType) Image {
        return Image{
            .alt_text = alt_text,
            .destination = destination,
            .link_type = link_type,
        };
    }
};

/// Autolink
pub const Autolink = struct {
    url: []const u8,
    is_email: bool = false,

    pub fn init(url: []const u8, is_email: bool) Autolink {
        return Autolink{
            .url = url,
            .is_email = is_email,
        };
    }
};

/// Footnote reference
pub const FootnoteReference = struct {
    label: []const u8,

    pub fn init(label: []const u8) FootnoteReference {
        return FootnoteReference{ .label = label };
    }
};

/// Hard line break
pub const HardBreak = struct {
    pub fn init() HardBreak {
        return HardBreak{};
    }
};

/// Soft line break
pub const SoftBreak = struct {
    pub fn init() SoftBreak {
        return SoftBreak{};
    }
};

/// Inline HTML
pub const HtmlInline = struct {
    content: []const u8,

    pub fn init(content: []const u8) HtmlInline {
        return HtmlInline{ .content = content };
    }
};
