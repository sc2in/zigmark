//! Markdown Abstract Syntax Tree (AST) definitions.
//!
//! This module defines every node type produced by the parser.  The tree is
//! rooted at a `Document` which contains a flat list of `Block` nodes, each
//! of which may recursively contain other blocks or `Inline` elements.
//!
//! The types closely follow the CommonMark specification §4 (leaf blocks)
//! and §6 (inlines), with extensions for footnotes.
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

/// Base node type for all AST elements.
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

/// The root of a parsed Markdown document.
///
/// A `Document` owns a flat list of top-level `Block` nodes.  Call
/// `deinit` when you are done to release all child allocations (unless
/// you are using an arena allocator that will be freed in bulk).
pub const Document = struct {
    children: std.ArrayList(Block),

    /// Create an empty document.
    pub fn init(allocator: std.mem.Allocator) Document {
        _ = allocator; // autofix
        return Document{
            .children = std.ArrayList(Block){},
        };
    }

    /// Recursively free every block (and its inlines) then release the list.
    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
    }

    /// Convenience query API for traversing and filtering the AST.
    ///
    /// Obtain a `Query` with `doc.get()` and then call helper methods
    /// such as `.headings()`, `.links()`, `.textAt()`, etc.
    pub const Query = struct {
        document: *const Document,

        /// Wrap `document` in a query handle.
        pub fn init(document: *const Document) Query {
            return Query{ .document = document };
        }

        /// Return every top-level block whose active tag equals `block_type`.
        pub fn blocks(self: Query, allocator: std.mem.Allocator, block_type: std.meta.Tag(Block)) !std.ArrayList(Block) {
            var results = std.ArrayList(Block){};

            for (self.document.children.items) |block| {
                if (std.meta.activeTag(block) == block_type) {
                    try results.append(allocator, block);
                }
            }

            return results;
        }

        /// Return all headings, optionally filtered to a single `level` (1–6).
        /// Pass `null` to return headings of every level.
        pub fn headings(self: Query, allocator: std.mem.Allocator, level: ?u8) !std.ArrayList(*const Heading) {
            var results = std.ArrayList(*const Heading){};

            for (self.document.children.items) |*block| {
                if (block.* == .heading) {
                    if (level) |target_level| {
                        if (block.heading.level == target_level) {
                            try results.append(allocator, &block.heading);
                        }
                    } else {
                        try results.append(allocator, &block.heading);
                    }
                }
            }

            return results;
        }

        /// Return every paragraph that contains at least one inline of `inline_type`.
        pub fn paragraphsWithInlines(self: Query, allocator: std.mem.Allocator, inline_type: std.meta.Tag(Inline)) !std.ArrayList(*const Paragraph) {
            var results = std.ArrayList(*const Paragraph){};

            for (self.document.children.items) |*block| {
                if (block.* == .paragraph) {
                    for (block.paragraph.children.items) |*inline_elem| {
                        if (std.meta.activeTag(inline_elem.*) == inline_type) {
                            try results.append(allocator, &block.paragraph);
                            break;
                        }
                    }
                }
            }

            return results;
        }

        /// Collect every `Link` inline across all blocks (paragraphs, headings,
        /// blockquotes, and list items) in document order.
        pub fn links(self: Query, allocator: std.mem.Allocator) !std.ArrayList(*const Link) {
            var results = std.ArrayList(*const Link){};

            for (self.document.children.items) |*block| {
                try self.collectLinksFromBlock(allocator, block, &results);
            }

            return results;
        }

        /// Look up text content by a simple path expression.
        ///
        /// Currently supports `"heading[N]"` where *N* is a zero-based index
        /// into `document.children`.  Returns the first `Text` inline of
        /// that heading, or `null` if the path doesn't resolve.
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

        /// Count the number of top-level blocks matching `block_type`.
        pub fn count(self: Query, block_type: std.meta.Tag(Block)) usize {
            var counter: usize = 0;

            for (self.document.children.items) |block| {
                if (std.meta.activeTag(block) == block_type) {
                    counter += 1;
                }
            }

            return counter;
        }

        // Helper functions
        fn collectLinksFromBlock(self: Query, allocator: std.mem.Allocator, block: *const Block, results: *std.ArrayList(*const Link)) !void {
            switch (block.*) {
                .paragraph => |*p| {
                    for (p.children.items) |*inline_elem| {
                        if (inline_elem.* == .link) {
                            try results.append(allocator, &inline_elem.link);
                        }
                    }
                },
                .heading => |*h| {
                    for (h.children.items) |*inline_elem| {
                        if (inline_elem.* == .link) {
                            try results.append(allocator, &inline_elem.link);
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
    };

    /// Return a `Query` handle for this document.
    ///
    /// Usage: `const q = doc.get(); const hdrs = try q.headings(alloc, 2);`
    pub fn get(self: *const Document) Query {
        return Query.init(self);
    }
};

/// A block-level element (CommonMark §4).
///
/// Block nodes form the top-level structure of a document: paragraphs,
/// headings, code blocks, lists, blockquotes, thematic breaks, raw HTML
/// blocks, and footnote definitions.
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
    table: Table,

    /// Recursively free this block and all children it owns.
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

/// An inline-level element (CommonMark §6).
///
/// Inline nodes live inside block nodes such as `Paragraph` or `Heading`.
/// They represent runs of text, emphasis, strong emphasis, code spans,
/// links, images, autolinks, footnote references, line breaks, and
/// inline HTML.
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

    /// Recursively free this inline and any children it owns.
    pub fn deinit(self: *Inline, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*in_line_elem| if (@hasDecl(@TypeOf(in_line_elem.*), "deinit")) {
                in_line_elem.deinit(allocator);
            },
        }
    }
};

/// A paragraph — a sequence of non-blank lines that cannot be interpreted
/// as other kinds of blocks (CommonMark §4.8).
pub const Paragraph = struct {
    children: std.ArrayList(Inline),
    /// Owned copy of the paragraph source text that inline `Text` nodes
    /// borrow from.  Freed in `deinit` after all children are released.
    inline_source: ?[]const u8 = null,

    /// Create an empty paragraph with no inline children.
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
        if (self.inline_source) |src| allocator.free(src);
    }
};

/// An ATX or setext heading (CommonMark §4.2 / §4.3).
///
/// `level` is 1–6 corresponding to `<h1>`–`<h6>`.  The inline content
/// of the heading (everything after the `#` markers or the underline)
/// is stored in `children`.
pub const Heading = struct {
    level: u8,
    children: std.ArrayList(Inline),
    /// Owned copy of the inline source text (used by setext headings whose
    /// inline nodes borrow from a paragraph's duped content buffer).
    inline_source: ?[]const u8 = null,

    /// Create a heading at the given `level` with no inline children.
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
        if (self.inline_source) |src| allocator.free(src);
    }
};

/// An indented code block (CommonMark §4.4).
///
/// Each line is indented by at least four spaces or one tab.  The
/// leading indentation is stripped; the remaining text is stored
/// verbatim in `content`.
pub const CodeBlock = struct {
    content: []const u8,

    /// Wrap `content` in an indented code block node.
    pub fn init(content: []const u8) CodeBlock {
        return CodeBlock{ .content = content };
    }
    pub fn deinit(self: *CodeBlock, allocator: Allocator) void {
        if (self.content.len > 0) allocator.free(self.content);
    }
};

/// A fenced code block (CommonMark §4.5).
///
/// Delimited by a line of at least three backticks (`` ` ``) or tildes (`~`).
/// An optional info string after the opening fence is exposed as `language`
/// (typically used for syntax highlighting hints).
pub const FencedCodeBlock = struct {
    content: []const u8,
    language: ?[]const u8 = null,
    fence_char: u8,
    fence_length: usize,

    /// Create a fenced code block with the given content and metadata.
    pub fn init(content: []const u8, language: ?[]const u8, fence_char: u8, fence_length: usize) FencedCodeBlock {
        return FencedCodeBlock{
            .content = content,
            .language = language,
            .fence_char = fence_char,
            .fence_length = fence_length,
        };
    }
    pub fn deinit(self: *FencedCodeBlock, allocator: Allocator) void {
        if (self.content.len > 0) allocator.free(self.content);
    }
};

/// A blockquote (CommonMark §5.1).
///
/// Lines are prefixed with `>`.  The contents are parsed recursively
/// so a blockquote may contain any block-level elements, including
/// nested blockquotes.
pub const Blockquote = struct {
    children: std.ArrayList(Block),

    /// Create an empty blockquote.
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

/// Discriminator for ordered (`1.`) vs unordered (`-`, `*`, `+`) lists.
pub const ListType = enum {
    ordered,
    unordered,
};

/// A single item inside a `List` (CommonMark §5.3).
///
/// Each item contains one or more `Block` children.  In a *tight* list
/// the paragraphs are rendered without `<p>` wrappers.
pub const ListItem = struct {
    children: std.ArrayList(Block),
    tight: bool = true,

    /// Create an empty list item.
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

/// An ordered or unordered list (CommonMark §5.3).
///
/// * `tight` — when `true` the list's item paragraphs are rendered
///   without `<p>` wrappers (a *tight* list in CommonMark terms).
/// * `start` — for ordered lists, the starting number (defaults to 1).
pub const List = struct {
    type: ListType,
    items: std.ArrayList(ListItem),
    tight: bool = true,
    start: ?usize = null,

    /// Create an empty list of the given type.
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

/// A thematic break — a horizontal rule rendered as `<hr />` (CommonMark §4.1).
///
/// Produced by a line containing three or more `*`, `-`, or `_` characters.
pub const ThematicBreak = struct {
    char: u8,

    /// Create a thematic break that was introduced by `char` (`*`, `-`, or `_`).
    pub fn init(char: u8) ThematicBreak {
        return ThematicBreak{ .char = char };
    }
    pub fn deinit(_: ThematicBreak, _: Allocator) void {}
};

/// A raw HTML block (CommonMark §4.6).
///
/// The `content` is passed through to the renderer verbatim — no
/// escaping or further parsing is performed.
pub const HtmlBlock = struct {
    content: []const u8,

    /// Wrap raw HTML `content` in an HTML block node.
    pub fn init(content: []const u8) HtmlBlock {
        return HtmlBlock{ .content = content };
    }
    pub fn deinit(self: *HtmlBlock, allocator: Allocator) void {
        if (self.content.len > 0) allocator.free(self.content);
    }
};

/// A footnote definition (`[^label]: …`).
///
/// This is an extension to CommonMark.  The `label` is the identifier
/// that `FootnoteReference` inlines link to.
pub const FootnoteDefinition = struct {
    label: []const u8,
    children: std.ArrayList(Block),

    /// Create an empty footnote definition for the given `label`.
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

/// A run of plain text (CommonMark §6.11, textual content).
pub const Text = struct {
    content: []const u8,

    /// Wrap a string slice in a `Text` inline node.
    pub fn init(content: []const u8) Text {
        return Text{ .content = content };
    }
    pub fn deinit(_: Text, _: Allocator) void {}
};

/// Emphasis — rendered as `<em>` (CommonMark §6.4).
///
/// Delimited by a single `*` or `_`.  `marker` records which delimiter
/// was used so a round-trip formatter can preserve the author's style.
pub const Emphasis = struct {
    children: std.ArrayList(Inline),
    marker: u8,

    /// Create an empty emphasis node with the given delimiter `marker`.
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

/// Strong emphasis — rendered as `<strong>` (CommonMark §6.4).
///
/// Delimited by `**` or `__`.  `marker` records which character was used.
pub const Strong = struct {
    children: std.ArrayList(Inline),
    marker: u8,

    /// Create an empty strong-emphasis node with the given delimiter `marker`.
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

/// A code span — inline code delimited by backticks (CommonMark §6.1).
///
/// Backtick strings of any length may be used; interior backtick runs
/// shorter than the delimiter are treated as literal characters.
pub const CodeSpan = struct {
    content: []const u8,

    /// Wrap `content` in a code span node.
    pub fn init(content: []const u8) CodeSpan {
        return CodeSpan{ .content = content };
    }
    pub fn deinit(self: *CodeSpan, allocator: Allocator) void {
        if (self.content.len > 0) allocator.free(self.content);
    }
};

/// The destination (URL) and optional title of a link or image.
///
/// In CommonMark, a link destination may be enclosed in angle brackets
/// (`<url>`) or written bare.  The title, if present, is enclosed in
/// `"…"`, `'…'`, or `(…)` (CommonMark §6.5 / §6.7).
pub const LinkDestination = struct {
    url: []const u8,
    title: ?[]const u8 = null,

    /// Create a link destination with the given URL and optional title.
    pub fn init(url: []const u8, title: ?[]const u8) LinkDestination {
        return LinkDestination{
            .url = url,
            .title = title,
        };
    }
};

/// How a link or image was specified in the source (CommonMark §6.5).
pub const LinkType = enum {
    /// `[text](url "title")` — inline link.
    in_line,
    /// `[text][label]` — full reference link.
    reference,
    /// `[text][]` — collapsed reference link (label == text).
    collapsed,
    /// `[text]` — shortcut reference link (label == text, no brackets).
    shortcut,
};

/// A hyperlink (CommonMark §6.5 – §6.7).
///
/// `children` are the visible inline elements between `[` and `]`.
/// The resolved URL and optional title are in `destination`.  For
/// reference-style links `link_type` indicates the flavour used and
/// `reference_label` stores the original label text.
pub const Link = struct {
    children: std.ArrayList(Inline),
    destination: LinkDestination,
    link_type: LinkType,
    reference_label: ?[]const u8 = null,

    /// Create a link with the given destination and no children.
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
        if (self.destination.url.len > 0) allocator.free(self.destination.url);
        if (self.destination.title) |t| if (t.len > 0) allocator.free(t);
    }
};

/// An image (CommonMark §6.8).
///
/// Syntactically identical to a link but prefixed with `!`.  The
/// `alt_text` is the content between `[` and `]`, rendered as the
/// `alt` attribute of the `<img>` tag.
pub const Image = struct {
    alt_text: []const u8,
    destination: LinkDestination,
    link_type: LinkType,
    reference_label: ?[]const u8 = null,

    /// Create an image node with the given alt text and destination.
    pub fn init(alt_text: []const u8, destination: LinkDestination, link_type: LinkType) Image {
        return Image{
            .alt_text = alt_text,
            .destination = destination,
            .link_type = link_type,
        };
    }
    pub fn deinit(self: *Image, allocator: Allocator) void {
        if (self.alt_text.len > 0) allocator.free(self.alt_text);
        if (self.destination.url.len > 0) allocator.free(self.destination.url);
        if (self.destination.title) |t| if (t.len > 0) allocator.free(t);
    }
};

/// An autolink — a URI or e-mail address enclosed in angle brackets
/// (CommonMark §6.9).
///
/// Example: `<https://example.com>` or `<user@host>`.
pub const Autolink = struct {
    url: []const u8,
    is_email: bool = false,

    /// Create an autolink node.
    pub fn init(url: []const u8, is_email: bool) Autolink {
        return Autolink{
            .url = url,
            .is_email = is_email,
        };
    }
};

/// An inline footnote reference (`[^label]`).
///
/// This is an extension to CommonMark.  The `label` matches a
/// corresponding `FootnoteDefinition` block elsewhere in the document.
pub const FootnoteReference = struct {
    label: []const u8,

    /// Create a footnote reference for the given `label`.
    pub fn init(label: []const u8) FootnoteReference {
        return FootnoteReference{ .label = label };
    }
};

/// A hard line break — rendered as `<br />` (CommonMark §6.10).
///
/// Produced by two or more trailing spaces before a newline, or by a
/// backslash at the end of a line.
pub const HardBreak = struct {
    pub fn init() HardBreak {
        return HardBreak{};
    }
};

/// A soft line break — rendered as a newline character (CommonMark §6.11).
///
/// Occurs at every line ending inside a paragraph that is not a hard break.
pub const SoftBreak = struct {
    pub fn init() SoftBreak {
        return SoftBreak{};
    }
};

/// Raw inline HTML (CommonMark §6.6).
///
/// Any HTML tag that appears in inline context is preserved verbatim.
pub const HtmlInline = struct {
    content: []const u8,

    /// Wrap raw inline HTML `content` in a node.
    pub fn init(content: []const u8) HtmlInline {
        return HtmlInline{ .content = content };
    }
};

/// Column alignment for GitHub Flavored Markdown tables.
///
/// Derived from the position of `:` in the table delimiter row.
/// For example:
/// `:---`  -> left
/// `:---:` -> center
/// `---:`  -> right
pub const TableAlignment = enum {
    none,
    left,
    center,
    right,
};

/// A single cell in a table row.
///
/// Each cell contains inline content parsed using the existing
/// inline parser, as well as an optional owned source slice
/// that the inlines may borrow from (mirroring Paragraph/Heading).
pub const TableCell = struct {
    children: std.ArrayList(Inline),
    inline_source: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) TableCell {
        _ = allocator; // autofix
        return TableCell{
            .children = std.ArrayList(Inline){},
        };
    }

    pub fn deinit(self: *TableCell, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
        if (self.inline_source) |src| allocator.free(src);
    }
};

/// A row within a table header or body.
///
/// `cells` holds one `TableCell` per column.  For a malformed table
/// line that does not provide enough cells, the parser will create
/// empty cells to match the column count.
pub const TableRow = struct {
    cells: std.ArrayList(TableCell),

    pub fn init(allocator: std.mem.Allocator) TableRow {
        _ = allocator; // autofix
        return TableRow{
            .cells = std.ArrayList(TableCell){},
        };
    }

    pub fn deinit(self: *TableRow, allocator: std.mem.Allocator) void {
        for (self.cells.items) |*cell| {
            cell.deinit(allocator);
        }
        self.cells.deinit(allocator);
    }
};

/// A GitHub Flavored Markdown table block.
///
/// The first row is treated as the header row.  `alignments.len`
/// defines the number of columns and the text alignment for each.
/// Every header and body row must have at most `alignments.len` cells;
/// missing cells are treated as empty, and extra cells are ignored
/// by the parser.
pub const Table = struct {
    alignments: std.ArrayList(TableAlignment),
    header: TableRow,
    body: std.ArrayList(TableRow),

    pub fn init(allocator: std.mem.Allocator) Table {
        return Table{
            .alignments = std.ArrayList(TableAlignment){},
            .header = TableRow.init(allocator),
            .body = std.ArrayList(TableRow){},
        };
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        self.header.deinit(allocator);

        for (self.body.items) |*row| {
            row.deinit(allocator);
        }
        self.body.deinit(allocator);

        self.alignments.deinit(allocator);
    }
};

test {
    _ = @import("query_test.zig");
}
