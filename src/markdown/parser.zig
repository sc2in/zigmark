const std = @import("std");
const mecha = @import("mecha");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;
const tst = std.testing;
const math = std.math;
const mem = std.mem;
const tokens = @import("tokens.zig");
const Token = tokens.Token;
const Range = tokens.Range;
const P2 = @import("parser2.zig");
const AST = @import("ast.zig");

// Result types for parsers
const HeadingResult = struct {
    level: u8,
    content: []const u8,
};

const LinkResult = struct {
    text: []const u8,
    url: []const u8,
};

const EmphasisResult = struct {
    marker: u8,
    content: []const u8,
};

const FootnoteRefResult = struct {
    label: []const u8,
};

const FootnoteDefResult = struct {
    label: []const u8,
    content: []const u8,
};

const ListItemResult = struct {
    marker: u8,
    content: []const u8,
};

const BlockquoteResult = struct {
    content: []const u8,
};

/// Basic character parsers using Mecha
pub const parsers = struct {
    pub const space = mecha.ascii.char(' ');
    pub const tab = mecha.ascii.char('\t');
    pub const newline = mecha.oneOf(.{ mecha.ascii.char('\n'), mecha.combine(.{ mecha.ascii.char('\r'), mecha.ascii.char('\n').opt() }) });

    pub const hash = mecha.ascii.char('#');
    pub const equals = mecha.ascii.char('=');
    pub const dash = mecha.ascii.char('-');
    pub const underscore = mecha.ascii.char('_');
    pub const asterisk = mecha.ascii.char('*');
    pub const plus = mecha.ascii.char('+');
    pub const gt = mecha.ascii.char('>');
    pub const backtick = mecha.ascii.char('`');
    pub const tilde = mecha.ascii.char('~');

    pub const lbracket = mecha.ascii.char('[');
    pub const rbracket = mecha.ascii.char(']');
    pub const lparen = mecha.ascii.char('(');
    pub const rparen = mecha.ascii.char(')');
    pub const caret = mecha.ascii.char('^');
    pub const colon = mecha.ascii.char(':');
    pub const backslash = mecha.ascii.char('\\');
    pub const lt = mecha.ascii.char('<');

    pub const digit = mecha.ascii.range('0', '9');
    pub const letter = mecha.oneOf(.{ mecha.ascii.range('a', 'z'), mecha.ascii.range('A', 'Z') });
    pub const alphanumeric = mecha.oneOf(.{ letter, digit });

    // Whitespace (excluding newlines)
    pub const whitespace = mecha.oneOf(.{ space, tab }).many(.{ .collect = false, .min = 1 });

    // URL characters for links
    pub const url_char = mecha.oneOf(.{
        alphanumeric,
        mecha.ascii.char('.'),
        mecha.ascii.char('/'),
        mecha.ascii.char(':'),
        mecha.ascii.char('?'),
        mecha.ascii.char('='),
        mecha.ascii.char('&'),
        mecha.ascii.char('#'),
        mecha.ascii.char('-'),
        mecha.ascii.char('_'),
        mecha.ascii.char('~'),
        mecha.ascii.char('%'),
    });

    // Text that is not special markdown characters
    pub const text_char = mecha.oneOf(.{
        letter,
        digit,
        mecha.ascii.char(' '),
        mecha.ascii.char('.'),
        mecha.ascii.char(','),
        mecha.ascii.char('!'),
        mecha.ascii.char('?'),
        mecha.ascii.char(';'),
        mecha.ascii.char('"'),
        mecha.ascii.char('\''),
        mecha.ascii.char(':'),
        mecha.ascii.char('-'),
        mecha.ascii.char('('),
        mecha.ascii.char(')'),
    });

    // Line ending
    pub const line_ending = mecha.oneOf(.{
        mecha.ascii.char('\n'),
        mecha.combine(.{ mecha.ascii.char('\r'), mecha.ascii.char('\n').opt() }),
    });

    // ATX heading parser
    pub fn atx_heading(allocator: std.mem.Allocator) mecha.Parser(HeadingResult) {
        _ = allocator; // autofix
        return mecha.combine(.{
            hash.many(.{ .collect = false, .min = 1, .max = 6 }),
            space,
            mecha.many(mecha.oneOf(.{
                text_char,
                mecha.ascii.char('*'),
                mecha.ascii.char('_'),
                mecha.ascii.char('['),
                mecha.ascii.char(']'),
                mecha.ascii.char('`'),
            }), .{ .collect = false }).asStr(),
            line_ending.opt(),
        }).map(struct {
            fn build(result: anytype) HeadingResult {
                return HeadingResult{
                    .level = @intCast(result[0].len),
                    .content = std.mem.trim(u8, result[2], " \t#"),
                };
            }
        }.build);
    }

    // Inline link parser: [text](url)
    pub fn in_line_link(allocator: std.mem.Allocator) mecha.Parser(LinkResult) {
        _ = allocator; // autofix
        return mecha.combine(.{
            lbracket,
            mecha.many(mecha.oneOf(.{
                text_char,
                mecha.ascii.char('*'),
                mecha.ascii.char('_'),
                mecha.ascii.char('`'),
            }), .{ .collect = false }).asStr(),
            rbracket,
            lparen,
            url_char.many(.{ .collect = false, .min = 1 }).asStr(),
            rparen,
        }).map(struct {
            fn build(result: anytype) LinkResult {
                return LinkResult{
                    .text = result[1],
                    .url = result[4],
                };
            }
        }.build);
    }

    // Emphasis parser: *text* or _text_
    pub fn emphasis(allocator: std.mem.Allocator) mecha.Parser(EmphasisResult) {
        _ = allocator; // autofix
        const asterisk_emphasis = mecha.combine(.{
            asterisk,
            mecha.many(mecha.oneOf(.{
                text_char,
                mecha.ascii.char('_'),
                mecha.ascii.char('['),
                mecha.ascii.char(']'),
                mecha.ascii.char('`'),
            }), .{ .collect = false }).asStr(),
            asterisk,
        }).map(struct {
            fn build(result: anytype) EmphasisResult {
                return EmphasisResult{
                    .marker = '*',
                    .content = result[1],
                };
            }
        }.build);

        const underscore_emphasis = mecha.combine(.{
            underscore,
            mecha.many(mecha.oneOf(.{
                text_char,
                mecha.ascii.char('*'),
                mecha.ascii.char('['),
                mecha.ascii.char(']'),
                mecha.ascii.char('`'),
            }), .{ .collect = false }).asStr(),
            underscore,
        }).map(struct {
            fn build(result: anytype) EmphasisResult {
                return EmphasisResult{
                    .marker = '_',
                    .content = result[1],
                };
            }
        }.build);

        return mecha.oneOf(.{ asterisk_emphasis, underscore_emphasis });
    }

    // Strong emphasis parser: **text** or __text__
    pub fn strong(allocator: std.mem.Allocator) mecha.Parser(EmphasisResult) {
        _ = allocator; // autofix
        const double_asterisk = mecha.combine(.{
            asterisk,
            asterisk,
            mecha.many(mecha.oneOf(.{
                text_char,
                mecha.ascii.char('_'),
                mecha.ascii.char('['),
                mecha.ascii.char(']'),
                mecha.ascii.char('`'),
            }), .{ .collect = false }).asStr(),
            asterisk,
            asterisk,
        }).map(struct {
            fn build(result: anytype) EmphasisResult {
                return EmphasisResult{
                    .marker = '*',
                    .content = result[2],
                };
            }
        }.build);

        const double_underscore = mecha.combine(.{
            underscore,
            underscore,
            mecha.many(mecha.oneOf(.{
                text_char,
                mecha.ascii.char('*'),
                mecha.ascii.char('['),
                mecha.ascii.char(']'),
                mecha.ascii.char('`'),
            }), .{ .collect = false }).asStr(),
            underscore,
            underscore,
        }).map(struct {
            fn build(result: anytype) EmphasisResult {
                return EmphasisResult{
                    .marker = '_',
                    .content = result[2],
                };
            }
        }.build);

        return mecha.oneOf(.{ double_asterisk, double_underscore });
    }

    // Footnote reference parser: [^label]
    pub fn footnote_reference(allocator: std.mem.Allocator) mecha.Parser(FootnoteRefResult) {
        _ = allocator; // autofix
        return mecha.combine(.{
            lbracket,
            caret,
            mecha.many(mecha.oneOf(.{ letter, digit }), .{ .collect = false, .min = 1 }).asStr(),
            rbracket,
        }).map(struct {
            fn build(result: anytype) FootnoteRefResult {
                return FootnoteRefResult{
                    .label = result[2],
                };
            }
        }.build);
    }

    // Footnote definition parser: [^label]: content
    pub fn footnote_definition(allocator: std.mem.Allocator) mecha.Parser(FootnoteDefResult) {
        _ = allocator; // autofix
        return mecha.combine(.{
            lbracket,
            caret,
            mecha.many(mecha.oneOf(.{ letter, digit }), .{ .collect = false, .min = 1 }).asStr(),
            rbracket,
            colon,
            space,
            mecha.rest.asStr(),
        }).map(struct {
            fn build(result: anytype) FootnoteDefResult {
                return FootnoteDefResult{
                    .label = result[2],
                    .content = std.mem.trim(u8, result[6], " \t\n\r"),
                };
            }
        }.build);
    }

    // Bullet list item parser: - item or * item or + item
    pub fn bullet_list_item(allocator: std.mem.Allocator) mecha.Parser(ListItemResult) {
        _ = allocator; // autofix
        return mecha.combine(.{
            mecha.oneOf(.{ dash, asterisk, plus }),
            space,
            mecha.rest.asStr(),
        }).map(struct {
            fn build(result: anytype) ListItemResult {
                return ListItemResult{
                    .marker = result[0],
                    .content = std.mem.trim(u8, result[2], " \t\n\r"),
                };
            }
        }.build);
    }

    // Blockquote parser: > content
    pub fn blockquote_line(allocator: std.mem.Allocator) mecha.Parser(BlockquoteResult) {
        _ = allocator; // autofix
        return mecha.combine(.{
            gt,
            space.opt(),
            mecha.rest.asStr(),
        }).map(struct {
            fn build(result: anytype) BlockquoteResult {
                return BlockquoteResult{
                    .content = std.mem.trim(u8, result[2], " \t\n\r"),
                };
            }
        }.build);
    }
};

const Self = @This();
pub fn init() Self {
    return Self{};
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    _ = self;
    _ = allocator;
}

// Enhanced in_line parser that handles all in_line elements
fn parseInlineElements(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(AST.Inline) {
    var in_lines = std.ArrayList(AST.Inline).init(allocator);
    var pos: usize = 0;

    while (pos < input.len) {
        // Try to parse in_line elements in order of precedence

        // Try strong emphasis first (** or __)
        if (pos + 1 < input.len and
            ((input[pos] == '*' and input[pos + 1] == '*') or
                (input[pos] == '_' and input[pos + 1] == '_')))
        {
            const marker = input[pos];
            var end_pos = pos + 2;
            var found_end = false;

            // Find closing marker
            while (end_pos + 1 < input.len) {
                if (input[end_pos] == marker and input[end_pos + 1] == marker) {
                    found_end = true;
                    break;
                }
                end_pos += 1;
            }

            if (found_end) {
                const content = input[pos + 2 .. end_pos];
                var strong_elem = AST.Strong.init(allocator, marker);
                try strong_elem.children.append(AST.Inline{ .text = AST.Text.init(content) });
                try in_lines.append(AST.Inline{ .strong = strong_elem });
                pos = end_pos + 2;
                continue;
            }
        }

        // Try emphasis (* or _)
        if (pos < input.len and (input[pos] == '*' or input[pos] == '_')) {
            const marker = input[pos];
            var end_pos = pos + 1;
            var found_end = false;

            // Find closing marker
            while (end_pos < input.len) {
                if (input[end_pos] == marker) {
                    found_end = true;
                    break;
                }
                end_pos += 1;
            }

            if (found_end and end_pos > pos + 1) {
                const content = input[pos + 1 .. end_pos];
                var emph_elem = AST.Emphasis.init(allocator, marker);
                try emph_elem.children.append(AST.Inline{ .text = AST.Text.init(content) });
                try in_lines.append(AST.Inline{ .emphasis = emph_elem });
                pos = end_pos + 1;
                continue;
            }
        }

        // Try in_line link [text](url)
        if (pos < input.len and input[pos] == '[') {
            var bracket_end = pos + 1;
            var found_bracket = false;

            // Find closing bracket
            while (bracket_end < input.len) {
                if (input[bracket_end] == ']') {
                    found_bracket = true;
                    break;
                }
                bracket_end += 1;
            }

            if (found_bracket and bracket_end + 1 < input.len and input[bracket_end + 1] == '(') {
                var paren_end = bracket_end + 2;
                var found_paren = false;

                // Find closing paren
                while (paren_end < input.len) {
                    if (input[paren_end] == ')') {
                        found_paren = true;
                        break;
                    }
                    paren_end += 1;
                }

                if (found_paren) {
                    const link_text = input[pos + 1 .. bracket_end];
                    const link_url = input[bracket_end + 2 .. paren_end];

                    const destination = AST.LinkDestination.init(link_url, null);
                    var link_elem = AST.Link.init(allocator, destination, .in_line);
                    try link_elem.children.append(AST.Inline{ .text = AST.Text.init(link_text) });
                    try in_lines.append(AST.Inline{ .link = link_elem });
                    pos = paren_end + 1;
                    continue;
                }
            }
        }

        // Try footnote reference [^label]
        if (pos + 1 < input.len and input[pos] == '[' and input[pos + 1] == '^') {
            var bracket_end = pos + 2;
            var found_bracket = false;

            // Find closing bracket
            while (bracket_end < input.len) {
                if (input[bracket_end] == ']') {
                    found_bracket = true;
                    break;
                }
                bracket_end += 1;
            }

            if (found_bracket and bracket_end > pos + 2) {
                const label = input[pos + 2 .. bracket_end];
                const footnote_ref = AST.FootnoteReference.init(label);
                try in_lines.append(AST.Inline{ .footnote_reference = footnote_ref });
                pos = bracket_end + 1;
                continue;
            }
        }

        // Default: collect text until next special character
        var text_end = pos;
        while (text_end < input.len and
            input[text_end] != '*' and input[text_end] != '_' and
            input[text_end] != '[' and input[text_end] != ']')
        {
            text_end += 1;
        }

        if (text_end > pos) {
            const text_content = input[pos..text_end];
            if (text_content.len > 0) {
                try in_lines.append(AST.Inline{ .text = .{ .content = text_content } });
            }
            pos = text_end;
        } else {
            // Skip single special character that couldn't be parsed
            pos += 1;
        }
    }

    return in_lines;
}

// Enhanced markdown parser using mecha combinators
pub fn parseMarkdown(_: Self, allocator: std.mem.Allocator, input: []const u8) !AST.Document {
    var doc = AST.Document.init(allocator);
    var lines = std.mem.splitAny(u8, input, "\n");

    var skip_lines = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // ignore frontmatter
        if (std.mem.eql(u8, trimmed, "---") or
            std.mem.eql(u8, trimmed, "+++") or
            std.mem.eql(u8, trimmed, "%%%"))
        {
            skip_lines = !skip_lines;
            continue;
        }
        if (trimmed.len == 0 or skip_lines) {
            continue;
        }

        // Try to parse as ATX heading
        if (trimmed[0] == '#') {
            var level: u8 = 0;
            var content_start: usize = 0;

            for (trimmed, 0..) |c, i| {
                if (c == '#') {
                    level += 1;
                } else if (c == ' ') {
                    content_start = i + 1;
                    break;
                } else {
                    break;
                }
            }

            if (level > 0 and level <= 6 and content_start > 0) {
                const content = std.mem.trim(u8, trimmed[content_start..], " \t#");
                var heading = AST.Heading.init(allocator, level);

                // Parse in_line elements in heading content
                const in_lines = try parseInlineElements(allocator, content);
                defer in_lines.deinit();
                for (in_lines.items) |in_line_elem| {
                    try heading.children.append(in_line_elem);
                }

                try doc.children.append(AST.Block{ .heading = heading });
                continue;
            }
        }

        // Try to parse as bullet list item
        if (trimmed.len > 2 and (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and trimmed[1] == ' ') {
            var list = AST.List.init(allocator, .unordered);
            var item = AST.ListItem.init(allocator);

            const content = trimmed[2..];
            var para = AST.Paragraph.init(allocator);

            // Parse in_line elements in list item content
            const in_lines = try parseInlineElements(allocator, content);
            defer in_lines.deinit();
            for (in_lines.items) |in_line_elem| {
                try para.children.append(in_line_elem);
            }

            try item.children.append(AST.Block{ .paragraph = para });
            try list.items.append(item);
            try doc.children.append(AST.Block{ .list = list });
            continue;
        }

        // Try to parse as blockquote
        if (trimmed.len > 1 and trimmed[0] == '>') {
            var bq = AST.Blockquote.init(allocator);
            const content = std.mem.trimLeft(u8, trimmed[1..], " \t");
            var para = AST.Paragraph.init(allocator);

            // Parse in_line elements in blockquote content
            const in_lines = try parseInlineElements(allocator, content);
            for (in_lines.items) |in_line_elem| {
                try para.children.append(in_line_elem);
            }

            try bq.children.append(AST.Block{ .paragraph = para });
            try doc.children.append(AST.Block{ .blockquote = bq });
            continue;
        }

        // Try to parse as footnote definition
        if (trimmed.len > 4 and std.mem.startsWith(u8, trimmed, "[^") and std.mem.indexOf(u8, trimmed, "]:") != null) {
            const colon_pos = std.mem.indexOf(u8, trimmed, "]:").?;
            const label = trimmed[2..colon_pos];
            const content = std.mem.trim(u8, trimmed[colon_pos + 2 ..], " \t");

            var footnote_def = AST.FootnoteDefinition.init(allocator, label);
            var para = AST.Paragraph.init(allocator);

            // Parse in_line elements in footnote content
            const in_lines = try parseInlineElements(allocator, content);
            defer in_lines.deinit();
            for (in_lines.items) |in_line_elem| {
                try para.children.append(in_line_elem);
            }

            try footnote_def.children.append(AST.Block{ .paragraph = para });
            try doc.children.append(AST.Block{ .footnote_definition = footnote_def });
            continue;
        }

        // Default: treat as paragraph
        var para = AST.Paragraph.init(allocator);

        // Parse in_line elements in paragraph content
        const in_lines = try parseInlineElements(allocator, trimmed);
        defer in_lines.deinit();
        for (in_lines.items) |in_line_elem| {
            try para.children.append(in_line_elem);
        }

        try doc.children.append(AST.Block{ .paragraph = para });
    }

    return doc;
}

test "basic character parsers" {
    const allocator = tst.allocator;

    // Test hash parser
    const hash_result = try parsers.hash.parse(allocator, "#hello");
    try tst.expect(hash_result.value == .ok);
    try tst.expectEqual(@as(u8, '#'), hash_result.value.ok);
    try tst.expectEqual(@as(usize, 1), hash_result.index);
}

fn ok(s: []const u8) !void {
    var parser = init();
    defer parser.deinit(tst.allocator);
    var res = try parser.parseMarkdown(tst.allocator, s);
    defer res.deinit(tst.allocator);
    errdefer res.deinit(tst.allocator);
}

test "heading" {
    try ok("# Heading\n");
    try ok("## Level 2\n");
    try ok("### Level 3\n");
}

test "paragraph" {
    try ok("Simple paragraph\n");
    try ok("Multiple words\n");
}

test "code block" {
    try ok("``````\n");
    try ok("``````\n");
}

test "list" {
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

test {
    tst.refAllDecls(@This());
}
