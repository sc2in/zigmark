//! Markdown parser.
//!
//! Transforms a UTF-8 Markdown string into an `AST.Document`.  The parser
//! operates in two passes:
//!
//!  1. **Link-reference-definition collection** — scans every line for
//!     `[label]: destination "title"` definitions and builds a lookup map.
//!  2. **Block / inline parsing** — identifies block structure (headings,
//!     lists, blockquotes, …) then parses inline content within each
//!     block, resolving emphasis, links (inline and reference), code
//!     spans, autolinks, etc.
//!
//! The public entry point is `parseMarkdown`.  All slice references in
//! the returned AST point into `input` or into buffers allocated with
//! the supplied allocator (ideally an `ArenaAllocator`).
//!
//! Block-level recognition is driven by the combinators and convenience
//! wrappers in the public `parsers` namespace.  Inline-level parsing uses
//! a hand-written state machine (CommonMark delimiter algorithm) because
//! emphasis nesting cannot be expressed as a pure combinator.
const std = @import("std");
const Allocator = std.mem.Allocator;
const tst = std.testing;
const mem = std.mem;

const mecha = @import("mecha");

const AST = @import("ast.zig");

// ── Public parser combinators & convenience wrappers ─────────────────────────

/// Low-level `mecha` parser combinators and convenience `try*` wrappers used
/// by the block parser.  Advanced callers may use the raw mecha parsers
/// directly; most code should prefer `parseMarkdown`.
pub const parsers = struct {

    // ── Result types ─────────────────────────────────────────────────────

    pub const HeadingResult = struct { level: u8, content: []const u8 };
    pub const BulletListResult = struct { marker: u8, content: []const u8 };
    pub const OrderedListResult = struct { num: u32, delimiter: u8, content: []const u8 };
    pub const BlockquoteResult = struct { content: []const u8 };
    pub const FootnoteDefResult = struct { label: []const u8, content: []const u8 };
    pub const FenceInfo = struct { char: u8, len: usize, info: []const u8 };

    // ── Character-level parsers ──────────────────────────────────────────

    pub const space = mecha.ascii.char(' ');
    pub const tab = mecha.ascii.char('\t');
    pub const newline = mecha.oneOf(.{
        mecha.ascii.char('\n'),
        mecha.combine(.{ mecha.ascii.char('\r'), mecha.ascii.char('\n').opt() }),
    });
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
    pub const whitespace = mecha.oneOf(.{ space, tab }).many(.{ .collect = false, .min = 1 });

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

    pub const text_char = mecha.oneOf(.{
        letter,                digit,
        mecha.ascii.char(' '), mecha.ascii.char('.'),
        mecha.ascii.char(','), mecha.ascii.char('!'),
        mecha.ascii.char('?'), mecha.ascii.char(';'),
        mecha.ascii.char('"'), mecha.ascii.char('\''),
        mecha.ascii.char(':'), mecha.ascii.char('-'),
        mecha.ascii.char('('), mecha.ascii.char(')'),
    });

    pub const line_ending = mecha.oneOf(.{
        mecha.ascii.char('\n'),
        mecha.combine(.{ mecha.ascii.char('\r'), mecha.ascii.char('\n').opt() }),
    });

    // ── Composite mecha parsers ──────────────────────────────────────────
    //
    // Declared as `pub const` so that mecha can resolve the `.map()`
    // callback types at comptime.  Use directly via `.parse(allocator,
    // input)`, or prefer the `try*` convenience wrappers below.

    /// ATX heading: 1-6 `#` chars, a space, then the rest of the line.
    /// Input should be trimmed of leading/trailing whitespace.
    pub const atx_heading = mecha.oneOf(.{
        // Heading with content after space
        mecha.combine(.{
            hash.many(.{ .collect = false, .min = 1, .max = 6 }),
            space,
            mecha.rest.asStr(),
        }).map(struct {
            fn f(r: anytype) HeadingResult {
                return .{
                    .level = @intCast(r[0].len),
                    .content = mem.trim(u8, r[2], " \t#"),
                };
            }
        }.f),
        // Empty heading (just hashes, no trailing content)
        hash.many(.{ .collect = false, .min = 1, .max = 6 }).map(struct {
            fn f(r: anytype) HeadingResult {
                return .{ .level = @intCast(r.len), .content = "" };
            }
        }.f),
    });

    /// Bullet list item: optional 0-3 spaces, then one of `-*+`, a space,
    /// then the rest of the line.
    pub const bullet_list_item = mecha.combine(.{
        space.many(.{ .collect = false, .min = 0, .max = 3 }),
        mecha.oneOf(.{ dash, asterisk, plus }),
        space,
        mecha.rest.asStr(),
    }).map(struct {
        fn f(r: anytype) BulletListResult {
            return .{
                .marker = r[1],
                .content = mem.trimLeft(u8, r[3], " \t"),
            };
        }
    }.f);

    /// Ordered list item: optional 0-3 spaces, 1-9 digits, `.` or `)`,
    /// a space, then the rest of the line.
    pub const ordered_list_item = mecha.combine(.{
        space.many(.{ .collect = false, .min = 0, .max = 3 }),
        digit.many(.{ .collect = false, .min = 1, .max = 9 }).asStr(),
        mecha.oneOf(.{ mecha.ascii.char('.'), mecha.ascii.char(')') }),
        space,
        mecha.rest.asStr(),
    }).map(struct {
        fn f(r: anytype) OrderedListResult {
            return .{
                .num = std.fmt.parseInt(u32, r[1], 10) catch 0,
                .delimiter = r[2],
                .content = mem.trimLeft(u8, r[4], " \t"),
            };
        }
    }.f);

    /// Blockquote line: optional leading whitespace, `>`, optional space,
    /// then the rest.
    pub const blockquote_line = mecha.combine(.{
        mecha.oneOf(.{ space, tab }).many(.{ .collect = false, .min = 0 }),
        gt,
        space.opt(),
        mecha.rest.asStr(),
    }).map(struct {
        fn f(r: anytype) BlockquoteResult {
            return .{ .content = mem.trim(u8, r[3], " \t\n\r") };
        }
    }.f);

    /// Footnote definition: `[^label]: content`
    pub const footnote_definition = mecha.combine(.{
        lbracket,
        caret,
        mecha.many(mecha.oneOf(.{ letter, digit }), .{ .collect = false, .min = 1 }).asStr(),
        rbracket,
        colon,
        space,
        mecha.rest.asStr(),
    }).map(struct {
        fn f(r: anytype) FootnoteDefResult {
            return .{
                .label = r[2],
                .content = mem.trim(u8, r[6], " \t\n\r"),
            };
        }
    }.f);

    // ── Convenience wrappers ─────────────────────────────────────────────
    //
    // Each `try*` function runs the corresponding mecha parser on a line
    // and returns an optional result.  These are the primary interface
    // used by the block parser.

    /// Try to parse an ATX heading from a raw line.
    pub fn tryAtxHeading(allocator: Allocator, line: []const u8) ?HeadingResult {
        const t = trimLine(line);
        if (t.len == 0 or t[0] != '#') return null;
        const result = atx_heading.parse(allocator, t) catch return null;
        return switch (result.value) {
            .ok => |v| v,
            else => null,
        };
    }

    /// Try to parse a bullet list marker from a line.
    pub fn tryBulletListItem(allocator: Allocator, line: []const u8) ?BulletListResult {
        if (line.len < 2) return null;
        const result = bullet_list_item.parse(allocator, line) catch return null;
        return switch (result.value) {
            .ok => |v| v,
            else => null,
        };
    }

    /// Try to parse an ordered list marker from a line.
    pub fn tryOrderedListItem(allocator: Allocator, line: []const u8) ?OrderedListResult {
        const result = ordered_list_item.parse(allocator, line) catch return null;
        return switch (result.value) {
            .ok => |v| v,
            else => null,
        };
    }

    /// Try to parse a blockquote marker from a raw line.
    /// Returns the content after the `> ` marker, or null.
    pub fn tryBlockquoteLine(allocator: Allocator, line: []const u8) ?[]const u8 {
        const t = mem.trimLeft(u8, line, " \t");
        if (t.len == 0 or t[0] != '>') return null;
        const result = blockquote_line.parse(allocator, line) catch return null;
        return switch (result.value) {
            .ok => |v| v.content,
            else => blk: {
                // Bare `>` with no trailing content
                if (t.len == 1) break :blk @as([]const u8, "");
                if (t[1] == ' ' or t[1] == '\t') break :blk t[2..];
                break :blk t[1..];
            },
        };
    }

    /// Try to parse a footnote definition from a (trimmed) line.
    pub fn tryFootnoteDef(allocator: Allocator, line: []const u8) ?FootnoteDefResult {
        const t = trimLine(line);
        if (!mem.startsWith(u8, t, "[^")) return null;
        const result = footnote_definition.parse(allocator, t) catch return null;
        return switch (result.value) {
            .ok => |v| v,
            else => null,
        };
    }

    /// Try to parse a fenced code block opening line.
    /// Handles backtick and tilde fences, info strings, and the rule
    /// that backtick fences cannot have backticks in the info string.
    pub fn tryFenceStart(line: []const u8) ?FenceInfo {
        var s: usize = 0;
        while (s < 3 and s < line.len and line[s] == ' ') s += 1;
        const t = line[s..];
        if (t.len < 3) return null;
        const c = t[0];
        if (c != '`' and c != '~') return null;
        var fl: usize = 0;
        while (fl < t.len and t[fl] == c) fl += 1;
        if (fl < 3) return null;
        const info = mem.trim(u8, t[fl..], " \t\r");
        if (c == '`' and mem.indexOf(u8, info, "`") != null) return null;
        return .{ .char = c, .len = fl, .info = info };
    }

    /// Check whether `line` closes a fenced code block opened by `fence`.
    pub fn isFenceEnd(line: []const u8, fence: FenceInfo) bool {
        const t = trimLine(line);
        var n: usize = 0;
        while (n < t.len and t[n] == fence.char) n += 1;
        if (n < fence.len) return false;
        return mem.trim(u8, t[n..], " \t").len == 0;
    }

    /// Try to parse an indented code line (4 spaces or 1 tab).
    pub fn tryIndentedCode(line: []const u8) ?[]const u8 {
        if (mem.startsWith(u8, line, "    ")) return line[4..];
        if (mem.startsWith(u8, line, "\t")) return line[1..];
        return null;
    }
};

// ── Block helpers ─────────────────────────────────────────────────────────────

fn trimLine(line: []const u8) []const u8 {
    return mem.trim(u8, line, " \t\r");
}

fn isBlankLine(line: []const u8) bool {
    return trimLine(line).len == 0;
}

/// 3+ of the same char (-, *, _) with optional spaces — thematic break.
fn isThematicBreak(line: []const u8) bool {
    const t = trimLine(line);
    if (t.len < 3) return false;
    const c = t[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var n: usize = 0;
    for (t) |ch| {
        if (ch == c) {
            n += 1;
        } else if (ch != ' ' and ch != '\t') {
            return false;
        }
    }
    return n >= 3;
}

/// All non-space chars are '=' (setext level-1 underline).
fn isSetextEqLine(line: []const u8) bool {
    const t = trimLine(line);
    if (t.len == 0) return false;
    for (t) |c| if (c != '=') return false;
    return true;
}

/// All non-space chars are '-' (setext level-2 underline / thematic break).
fn isSetextDashLine(line: []const u8) bool {
    const t = trimLine(line);
    if (t.len == 0) return false;
    for (t) |c| if (c != '-') return false;
    return true;
}

/// Compute the number of leading spaces on a raw line.
fn countLeadingSpaces(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| {
        if (c == ' ') {
            n += 1;
        } else if (c == '\t') {
            n += 4 - (n % 4);
        } else break;
    }
    return n;
}

/// For a bullet list marker, compute the content column.
/// Returns the column where content starts (marker indent + marker + spaces after marker),
/// or null if not a valid bullet list item.
fn bulletListContentColumn(line: []const u8) ?struct { col: usize, marker: u8 } {
    var pos: usize = 0;
    var col: usize = 0;
    // Skip 0-3 leading spaces
    while (pos < line.len and col < 4 and (line[pos] == ' ' or line[pos] == '\t')) {
        if (line[pos] == '\t') {
            col += 4 - (col % 4);
        } else {
            col += 1;
        }
        pos += 1;
    }
    if (col >= 4) return null;
    if (pos >= line.len) return null;
    const marker = line[pos];
    if (marker != '-' and marker != '*' and marker != '+') return null;
    pos += 1;
    col += 1;
    // Must be followed by at least one space (or end of line for blank item)
    if (pos >= line.len) return .{ .col = col + 1, .marker = marker }; // blank item
    if (line[pos] != ' ' and line[pos] != '\t') return null;
    // Count spaces after marker (at least 1, content column is where first non-space is)
    const marker_col = col;
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) {
        if (line[pos] == '\t') {
            col += 4 - (col % 4);
        } else {
            col += 1;
        }
        pos += 1;
    }
    // If the rest of the line is blank, content column is marker_col + 1
    if (pos >= line.len) return .{ .col = marker_col + 1, .marker = marker };
    // CommonMark: if indentation from marker to content is > 4, it's code
    // and the effective content column is marker_col + 1
    if (col - marker_col > 4) return .{ .col = marker_col + 1, .marker = marker };
    return .{ .col = col, .marker = marker };
}

/// For an ordered list marker, compute the content column.
/// Returns the column where content starts, the number, and delimiter.
fn orderedListContentColumn(line: []const u8) ?struct { col: usize, num: u32, delimiter: u8 } {
    var pos: usize = 0;
    var col: usize = 0;
    // Skip 0-3 leading spaces
    while (pos < line.len and col < 4 and (line[pos] == ' ' or line[pos] == '\t')) {
        if (line[pos] == '\t') {
            col += 4 - (col % 4);
        } else {
            col += 1;
        }
        pos += 1;
    }
    if (col >= 4) return null;
    // 1-9 digits
    const digit_start = pos;
    while (pos < line.len and line[pos] >= '0' and line[pos] <= '9') pos += 1;
    const digit_count = pos - digit_start;
    if (digit_count == 0 or digit_count > 9) return null;
    col += digit_count;
    // Delimiter: . or )
    if (pos >= line.len) return null;
    const delimiter = line[pos];
    if (delimiter != '.' and delimiter != ')') return null;
    pos += 1;
    col += 1;
    // Must be followed by at least one space (or end of line for blank item)
    if (pos >= line.len) {
        const num = std.fmt.parseInt(u32, line[digit_start .. digit_start + digit_count], 10) catch return null;
        return .{ .col = col + 1, .num = num, .delimiter = delimiter };
    }
    if (line[pos] != ' ' and line[pos] != '\t') return null;
    const marker_col = col;
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) {
        if (line[pos] == '\t') {
            col += 4 - (col % 4);
        } else {
            col += 1;
        }
        pos += 1;
    }
    const num = std.fmt.parseInt(u32, line[digit_start .. digit_start + digit_count], 10) catch return null;
    if (pos >= line.len) return .{ .col = marker_col + 1, .num = num, .delimiter = delimiter };
    if (col - marker_col > 4) return .{ .col = marker_col + 1, .num = num, .delimiter = delimiter };
    return .{ .col = col, .num = num, .delimiter = delimiter };
}

/// Extract the content of a line relative to a content column.
/// Returns the portion of the line starting at the content column, or null
/// if the line is not indented to at least that column.
fn extractLineContent(line: []const u8, content_col: usize) ?[]const u8 {
    var pos: usize = 0;
    var col: usize = 0;
    while (pos < line.len and col < content_col) {
        if (line[pos] == '\t') {
            col += 4 - (col % 4);
        } else if (line[pos] == ' ') {
            col += 1;
        } else break;
        pos += 1;
    }
    if (col < content_col) return null;
    // If we overshot (tab jumped past content_col), prepend spaces
    return line[pos..];
}

/// Check whether a line is a blank bullet list item (marker followed by nothing).
fn isBulletItemBlank(line: []const u8) bool {
    const info = bulletListContentColumn(line) orelse return false;
    _ = info;
    const t = trimLine(line);
    return t.len == 1 and (t[0] == '-' or t[0] == '*' or t[0] == '+');
}

/// Check whether a line is a blank ordered list item.
fn isOrderedItemBlank(line: []const u8) bool {
    const t = trimLine(line);
    if (t.len < 2) return false;
    var i: usize = 0;
    while (i < t.len and t[i] >= '0' and t[i] <= '9') i += 1;
    if (i == 0 or i >= t.len) return false;
    if (t[i] != '.' and t[i] != ')') return false;
    return i + 1 == t.len; // nothing after delimiter
}

/// Returns true when `t` (trimmed) starts a block that terminates a paragraph.
/// Implements CommonMark list interruption rules:
/// - Bullet lists can interrupt a paragraph (but not empty items)
/// - Ordered lists can only interrupt a paragraph if they start with 1
/// - Empty list items cannot interrupt a paragraph
fn isParaBreak(allocator: Allocator, t: []const u8, raw: []const u8) bool {
    if (t.len == 0) return true;
    if (t[0] == '#') return true;
    if (t[0] == '>') return true;
    if (isThematicBreak(t)) return true;
    // Bullet list items can interrupt paragraphs, but not empty ones
    if (bulletListContentColumn(raw)) |_| {
        if (!isBulletItemBlank(raw)) return true;
    }
    // Ordered list items can only interrupt paragraphs if they start with 1
    if (orderedListContentColumn(raw)) |info| {
        if (info.num == 1 and !isOrderedItemBlank(raw)) return true;
    }
    if (parsers.tryFenceStart(raw) != null) return true;
    if (parsers.tryFootnoteDef(allocator, t) != null) return true;
    if (isLinkRefDefLine(raw)) return true;
    return false;
}

/// Quick check: does this line look like it starts a link reference definition?
fn isLinkRefDefLine(line: []const u8) bool {
    const t = mem.trimLeft(u8, line, " ");
    if (t.len < 4) return false;
    if (t[0] != '[') return false;
    if (t.len > 1 and t[1] == '^') return false;
    return parseLinkRefDef(line) != null;
}

/// Quick check: is this line the start of a standalone block element?
fn isStandaloneBlockStart(allocator: Allocator, line: []const u8) bool {
    _ = allocator; // autofix
    const t = trimLine(line);
    if (t.len == 0) return true;
    if (t[0] == '#') return true;
    if (t[0] == '>') return true;
    if (isThematicBreak(t)) return true;
    if (bulletListContentColumn(line) != null) return true;
    if (orderedListContentColumn(line) != null) return true;
    if (parsers.tryFenceStart(line) != null) return true;
    if (isLinkRefDefLine(line)) return true;
    return false;
}

// ── Link reference definitions ────────────────────────────────────────────────

/// Stores resolved link reference definitions: label → (url, title)
const RefMap = std.StringHashMap(struct { url: []const u8, title: ?[]const u8 });

/// Case-insensitive label normalization: collapse whitespace, lowercase ASCII.
fn normalizeLabel(allocator: Allocator, label: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8){};
    var prev_ws = true;
    for (label) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!prev_ws) {
                try buf.append(allocator, ' ');
                prev_ws = true;
            }
        } else {
            try buf.append(allocator, if (c >= 'A' and c <= 'Z') c + 32 else c);
            prev_ws = false;
        }
    }
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') _ = buf.pop();
    return buf.toOwnedSlice(allocator);
}

/// Parse a link reference definition line.
/// Format: [label]: <destination> "title"
fn parseLinkRefDef(line: []const u8) ?struct { label: []const u8, url: []const u8, title: ?[]const u8, consumed: usize } {
    var pos: usize = 0;
    while (pos < 3 and pos < line.len and line[pos] == ' ') pos += 1;
    if (pos >= line.len or line[pos] != '[') return null;
    pos += 1;
    const label_start = pos;
    while (pos < line.len) {
        if (line[pos] == '\\' and pos + 1 < line.len) {
            pos += 2;
        } else if (line[pos] == ']') {
            break;
        } else if (line[pos] == '[') {
            return null;
        } else {
            pos += 1;
        }
    }
    if (pos >= line.len) return null;
    const label = line[label_start..pos];
    if (label.len == 0) return null;
    var all_ws = true;
    for (label) |c| if (c != ' ' and c != '\t' and c != '\n') {
        all_ws = false;
        break;
    };
    if (all_ws) return null;

    pos += 1;
    if (pos >= line.len or line[pos] != ':') return null;
    pos += 1;

    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    if (pos < line.len and line[pos] == '\n') {
        pos += 1;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    }
    if (pos >= line.len) return null;

    var url: []const u8 = undefined;
    if (line[pos] == '<') {
        pos += 1;
        const url_start = pos;
        while (pos < line.len and line[pos] != '>' and line[pos] != '\n') {
            if (line[pos] == '\\' and pos + 1 < line.len) {
                pos += 2;
            } else {
                pos += 1;
            }
        }
        if (pos >= line.len or line[pos] != '>') return null;
        url = line[url_start..pos];
        pos += 1;
    } else {
        const url_start = pos;
        var paren_depth: i32 = 0;
        while (pos < line.len) {
            const c = line[pos];
            if (c == '\\' and pos + 1 < line.len) {
                pos += 2;
            } else if (c == '(') {
                paren_depth += 1;
                pos += 1;
            } else if (c == ')') {
                if (paren_depth == 0) break;
                paren_depth -= 1;
                pos += 1;
            } else if (c == ' ' or c == '\t' or c == '\n') {
                break;
            } else if (c <= 0x1f) {
                return null;
            } else {
                pos += 1;
            }
        }
        if (paren_depth != 0) return null;
        url = line[url_start..pos];
    }

    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    if (pos < line.len and line[pos] == '\n') {
        pos += 1;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    }

    var title: ?[]const u8 = null;
    if (pos < line.len and (line[pos] == '"' or line[pos] == '\'' or line[pos] == '(')) {
        const title_open = line[pos];
        const title_close: u8 = if (title_open == '(') ')' else title_open;
        pos += 1;
        const title_start = pos;
        while (pos < line.len) {
            if (line[pos] == '\\' and pos + 1 < line.len) {
                pos += 2;
            } else if (line[pos] == title_close) {
                break;
            } else {
                pos += 1;
            }
        }
        if (pos >= line.len) return null;
        title = line[title_start..pos];
        pos += 1;
    }

    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    if (pos < line.len and line[pos] != '\n') return null;

    return .{ .label = label, .url = url, .title = title, .consumed = pos };
}

// ── Inline parser ─────────────────────────────────────────────────────────────

fn isAsciiPunct(c: u8) bool {
    return (c >= '!' and c <= '/') or (c >= ':' and c <= '@') or
        (c >= '[' and c <= '`') or (c >= '{' and c <= '~');
}

fn isUriAutolink(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '+' or c == '-' or c == '.')) break;
    }
    if (i == 0 or i >= s.len or s[i] != ':') return false;
    for (s) |c| if (c == ' ' or c == '<' or c == '>') return false;
    return true;
}

fn isEmailAutolink(s: []const u8) bool {
    const at = mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at + 1 >= s.len) return false;
    return mem.indexOf(u8, s, " ") == null;
}

/// Try to parse [text](url "title") or [text](url) starting at `start` ('[').
fn tryParseLink(input: []const u8, start: usize) ?struct {
    text: []const u8,
    url: []const u8,
    title: ?[]const u8,
    end: usize,
} {
    if (start >= input.len or input[start] != '[') return null;

    var be: usize = start + 1;
    while (be < input.len and input[be] != ']') {
        if (input[be] == '\\' and be + 1 < input.len) {
            be += 2;
        } else {
            be += 1;
        }
    }
    if (be >= input.len) return null;
    const link_text = input[start + 1 .. be];

    if (be + 1 >= input.len or input[be + 1] != '(') return null;

    var pos = be + 2;

    while (pos < input.len and (input[pos] == ' ' or input[pos] == '\t' or input[pos] == '\n' or input[pos] == '\r')) pos += 1;
    if (pos >= input.len) return null;

    var url: []const u8 = undefined;
    if (pos < input.len and input[pos] == '<') {
        const url_start = pos + 1;
        pos += 1;
        while (pos < input.len) {
            if (input[pos] == '\\' and pos + 1 < input.len) {
                pos += 2;
            } else if (input[pos] == '>') {
                break;
            } else if (input[pos] == '<' or input[pos] == '\n') {
                return null;
            } else {
                pos += 1;
            }
        }
        if (pos >= input.len) return null;
        url = input[url_start..pos];
        pos += 1;
    } else if (pos < input.len and input[pos] == ')') {
        url = "";
    } else {
        const url_start = pos;
        var paren_depth: i32 = 0;
        while (pos < input.len) {
            const ch = input[pos];
            if (ch == '\\' and pos + 1 < input.len and isAsciiPunct(input[pos + 1])) {
                pos += 2;
            } else if (ch == '(') {
                paren_depth += 1;
                pos += 1;
            } else if (ch == ')') {
                if (paren_depth == 0) break;
                paren_depth -= 1;
                pos += 1;
            } else if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                break;
            } else if (ch <= 0x1f) {
                return null;
            } else {
                pos += 1;
            }
        }
        if (paren_depth != 0) return null;
        url = input[url_start..pos];
    }

    while (pos < input.len and (input[pos] == ' ' or input[pos] == '\t' or input[pos] == '\n' or input[pos] == '\r')) pos += 1;
    if (pos >= input.len) return null;

    var title: ?[]const u8 = null;
    if (input[pos] == ')') {
        return .{ .text = link_text, .url = url, .title = title, .end = pos + 1 };
    }

    const title_open = input[pos];
    const title_close: u8 = switch (title_open) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };
    pos += 1;
    const title_start = pos;
    while (pos < input.len) {
        if (input[pos] == '\\' and pos + 1 < input.len) {
            pos += 2;
        } else if (input[pos] == title_close) {
            break;
        } else {
            pos += 1;
        }
    }
    if (pos >= input.len) return null;
    title = input[title_start..pos];
    pos += 1;

    while (pos < input.len and (input[pos] == ' ' or input[pos] == '\t' or input[pos] == '\n' or input[pos] == '\r')) pos += 1;
    if (pos >= input.len or input[pos] != ')') return null;

    return .{ .text = link_text, .url = url, .title = title, .end = pos + 1 };
}

// ── CommonMark delimiter-based emphasis algorithm ─────────────────────────────

fn isUnicodeWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c or c == 0x0b;
}

fn isUnicodePunct(input: []const u8, pos: usize) bool {
    if (pos >= input.len) return false;
    const c = input[pos];
    if (isAsciiPunct(c)) return true;
    if (c >= 0x80) {
        if (c < 0xC0) return false;
        if (c >= 0xC0 and c < 0xE0) {
            if (pos + 1 >= input.len) return false;
            const cp = (@as(u32, c & 0x1F) << 6) | @as(u32, input[pos + 1] & 0x3F);
            return isUnicodeCodepointPunct(cp);
        }
        if (c >= 0xE0 and c < 0xF0) {
            if (pos + 2 >= input.len) return false;
            const cp = (@as(u32, c & 0x0F) << 12) |
                (@as(u32, input[pos + 1] & 0x3F) << 6) |
                @as(u32, input[pos + 2] & 0x3F);
            return isUnicodeCodepointPunct(cp);
        }
        if (c >= 0xF0) {
            if (pos + 3 >= input.len) return false;
            const cp = (@as(u32, c & 0x07) << 18) |
                (@as(u32, input[pos + 1] & 0x3F) << 12) |
                (@as(u32, input[pos + 2] & 0x3F) << 6) |
                @as(u32, input[pos + 3] & 0x3F);
            return isUnicodeCodepointPunct(cp);
        }
    }
    return false;
}

/// Check if a Unicode codepoint is in a punctuation or symbol category.
/// Uses sorted range tables with linear scan (sufficient for the number
/// of ranges involved; a binary search wrapper is trivial to add later).
fn isUnicodeCodepointPunct(cp: u32) bool {
    // Merged, sorted (start, end-inclusive) ranges covering Unicode categories
    // Pc, Pd, Ps, Pe, Pi, Pf, Po, Sm, Sc, Sk, So that CommonMark treats as
    // punctuation.  ASCII range (0x00–0x7F) is handled by isAsciiPunct above
    // so the table starts at 0x00A1.
    const ranges = [_][2]u32{
        .{ 0x00A1, 0x00A9 }, .{ 0x00AB, 0x00AC }, .{ 0x00AE, 0x00B1 },
        .{ 0x00B4, 0x00B4 }, .{ 0x00B6, 0x00B8 }, .{ 0x00BB, 0x00BB },
        .{ 0x00BF, 0x00BF }, .{ 0x00D7, 0x00D7 }, .{ 0x00F7, 0x00F7 },
        .{ 0x037E, 0x037E }, .{ 0x0387, 0x0387 }, .{ 0x055A, 0x055F },
        .{ 0x0589, 0x058A }, .{ 0x05BE, 0x05BE }, .{ 0x05C0, 0x05C6 },
        .{ 0x0609, 0x060D }, .{ 0x061B, 0x061B }, .{ 0x061D, 0x061F },
        .{ 0x066A, 0x066D }, .{ 0x06D4, 0x06D4 }, .{ 0x0F3A, 0x0F3D },
        .{ 0x1400, 0x1400 }, .{ 0x169B, 0x169C }, .{ 0x1806, 0x1806 },
        .{ 0x2010, 0x2027 }, .{ 0x2030, 0x205E }, .{ 0x2190, 0x23FF },
        .{ 0x2500, 0x27BF }, .{ 0x27C5, 0x27EF }, .{ 0x2900, 0x2998 },
        .{ 0x29D8, 0x29DB }, .{ 0x29FC, 0x29FD }, .{ 0x2CF9, 0x2CFF },
        .{ 0x2E00, 0x2E42 }, .{ 0x3001, 0x3003 }, .{ 0x3008, 0x301F },
        .{ 0x3030, 0x3030 }, .{ 0x303D, 0x303D }, .{ 0x30A0, 0x30A0 },
        .{ 0xFD3E, 0xFD3F }, .{ 0xFE17, 0xFE18 }, .{ 0xFE31, 0xFE44 },
        .{ 0xFE47, 0xFE4F }, .{ 0xFE50, 0xFE5E }, .{ 0xFE63, 0xFE63 },
        .{ 0xFF08, 0xFF09 }, .{ 0xFF0D, 0xFF0D }, .{ 0xFF3B, 0xFF3F },
        .{ 0xFF5B, 0xFF5D }, .{ 0xFF5F, 0xFF63 },
    };
    for (ranges) |r| {
        if (cp < r[0]) return false; // sorted: no point continuing
        if (cp <= r[1]) return true;
    }
    return false;
}

fn isLeftFlanking(input: []const u8, run_start: usize, run_len: usize) bool {
    const run_end = run_start + run_len;
    if (run_end >= input.len) return false;
    if (isUnicodeWhitespace(input[run_end])) return false;
    const followed_by_punct = isUnicodePunct(input, run_end);
    if (!followed_by_punct) return true;
    if (run_start == 0) return true;
    if (isUnicodeWhitespace(input[run_start - 1])) return true;
    if (isUnicodePunct(input, run_start - 1)) return true;
    return false;
}

fn isRightFlanking(input: []const u8, run_start: usize, run_len: usize) bool {
    const run_end = run_start + run_len;
    if (run_start == 0) return false;
    if (isUnicodeWhitespace(input[run_start - 1])) return false;
    const preceded_by_punct = isUnicodePunct(input, run_start - 1);
    if (!preceded_by_punct) return true;
    if (run_end >= input.len) return true;
    if (isUnicodeWhitespace(input[run_end])) return true;
    if (isUnicodePunct(input, run_end)) return true;
    return false;
}

fn canOpen(input: []const u8, marker: u8, run_start: usize, run_len: usize) bool {
    const lf = isLeftFlanking(input, run_start, run_len);
    if (marker == '*') return lf;
    const rf = isRightFlanking(input, run_start, run_len);
    return lf and (!rf or (run_start > 0 and isUnicodePunct(input, run_start - 1)));
}

fn canClose(input: []const u8, marker: u8, run_start: usize, run_len: usize) bool {
    const rf = isRightFlanking(input, run_start, run_len);
    if (marker == '*') return rf;
    const lf = isLeftFlanking(input, run_start, run_len);
    const run_end = run_start + run_len;
    return rf and (!lf or (run_end < input.len and isUnicodePunct(input, run_end)));
}

const Delimiter = struct {
    inline_idx: usize,
    input_pos: usize,
    count: usize,
    orig_count: usize,
    marker: u8,
    can_open: bool,
    can_close: bool,
    active: bool,
};

fn parseInlineElements(allocator: Allocator, input: []const u8, ref_map: ?*const RefMap) !std.ArrayList(AST.Inline) {
    var inlines = std.ArrayList(AST.Inline){};
    var delimiters = std.ArrayList(Delimiter){};
    defer delimiters.deinit(allocator);
    var pos: usize = 0;

    while (pos < input.len) {
        const c = input[pos];

        // Backslash escape
        if (c == '\\' and pos + 1 < input.len) {
            if (isAsciiPunct(input[pos + 1])) {
                try inlines.append(allocator, .{ .text = .{ .content = input[pos + 1 .. pos + 2] } });
                pos += 2;
                continue;
            } else if (input[pos + 1] == '\n') {
                try inlines.append(allocator, .{ .hard_break = .{} });
                pos += 2;
                continue;
            }
        }

        // Code span
        if (c == '`') {
            var tl: usize = 0;
            while (pos + tl < input.len and input[pos + tl] == '`') tl += 1;
            const cs = pos + tl;
            var se = cs;
            var found = false;
            while (se < input.len) {
                if (input[se] == '`') {
                    var cl: usize = 0;
                    while (se + cl < input.len and input[se + cl] == '`') cl += 1;
                    if (cl == tl) {
                        const raw = input[cs..se];
                        var code_buf = std.ArrayList(u8){};
                        for (raw) |ch| {
                            if (ch == '\n') {
                                try code_buf.append(allocator, ' ');
                            } else {
                                try code_buf.append(allocator, ch);
                            }
                        }
                        const code_content = code_buf.items;
                        var final_content: []const u8 = code_content;
                        if (code_content.len >= 2 and code_content[0] == ' ' and code_content[code_content.len - 1] == ' ') {
                            var all_spaces = true;
                            for (code_content) |ch| {
                                if (ch != ' ') {
                                    all_spaces = false;
                                    break;
                                }
                            }
                            if (!all_spaces) {
                                final_content = code_content[1 .. code_content.len - 1];
                            }
                        }
                        const duped = try allocator.dupe(u8, final_content);
                        code_buf.deinit(allocator);
                        try inlines.append(allocator, .{ .code_span = .{ .content = duped } });
                        pos = se + cl;
                        found = true;
                        break;
                    }
                    se += cl;
                } else {
                    se += 1;
                }
            }
            if (found) continue;
            try inlines.append(allocator, .{ .text = .{ .content = input[pos .. pos + tl] } });
            pos += tl;
            continue;
        }

        // Raw HTML tags / Autolinks
        if (c == '<') {
            if (mem.indexOfScalarPos(u8, input, pos + 1, '>')) |close| {
                const inner = input[pos + 1 .. close];
                if (isUriAutolink(inner)) {
                    try inlines.append(allocator, .{ .autolink = .{ .url = inner, .is_email = false } });
                    pos = close + 1;
                    continue;
                }
                if (isEmailAutolink(inner)) {
                    try inlines.append(allocator, .{ .autolink = .{ .url = inner, .is_email = true } });
                    pos = close + 1;
                    continue;
                }
            }
            if (tryParseHtmlTag(input, pos)) |tag_end| {
                try inlines.append(allocator, .{ .html_in_line = .{ .content = input[pos..tag_end] } });
                pos = tag_end;
                continue;
            }
        }

        // Image ![alt](url) or ![alt][ref]
        if (c == '!' and pos + 1 < input.len and input[pos + 1] == '[') {
            if (tryParseLink(input, pos + 1)) |r| {
                const alt_text = try flattenInlineText(allocator, r.text, ref_map);
                try inlines.append(allocator, .{ .image = .{
                    .alt_text = alt_text,
                    .destination = .{ .url = r.url, .title = r.title },
                    .link_type = .in_line,
                } });
                pos = r.end;
                continue;
            }
            if (ref_map) |rm| {
                if (tryParseImageRefLink(allocator, input, pos, rm)) |result| {
                    try inlines.append(allocator, result.inline_node);
                    pos = result.end;
                    continue;
                }
            }
        }

        // Footnote ref [^label] or inline link [text](url) or reference link
        if (c == '[') {
            if (pos + 1 < input.len and input[pos + 1] == '^') {
                if (mem.indexOfScalarPos(u8, input, pos + 2, ']')) |close| {
                    if (close > pos + 2) {
                        try inlines.append(allocator, .{ .footnote_reference = .{
                            .label = input[pos + 2 .. close],
                        } });
                        pos = close + 1;
                        continue;
                    }
                }
            }
            if (tryParseLink(input, pos)) |r| {
                var link = AST.Link.init(allocator, .{ .url = r.url, .title = r.title }, .in_line);
                var nested = try parseInlineElements(allocator, r.text, ref_map);
                defer nested.deinit(allocator);
                for (nested.items) |item| try link.children.append(allocator, item);
                try inlines.append(allocator, .{ .link = link });
                pos = r.end;
                continue;
            }
            if (ref_map) |rm| {
                if (tryParseRefLink(allocator, input, pos, rm)) |result| {
                    try inlines.append(allocator, result.inline_node);
                    pos = result.end;
                    continue;
                }
            }
        }

        // Emphasis/strong delimiter run
        if (c == '*' or c == '_') {
            const marker = c;
            const run_start = pos;
            var run_len: usize = 0;
            while (pos + run_len < input.len and input[pos + run_len] == marker) run_len += 1;

            const opens = canOpen(input, marker, run_start, run_len);
            const closes = canClose(input, marker, run_start, run_len);

            try inlines.append(allocator, .{ .text = .{ .content = input[run_start .. run_start + run_len] } });

            if (opens or closes) {
                try delimiters.append(allocator, .{
                    .inline_idx = inlines.items.len - 1,
                    .input_pos = run_start,
                    .count = run_len,
                    .orig_count = run_len,
                    .marker = marker,
                    .can_open = opens,
                    .can_close = closes,
                    .active = true,
                });
            }

            pos += run_len;
            continue;
        }

        // Plain text
        var te = pos;
        while (te < input.len) {
            const ch = input[te];
            if (ch == '*' or ch == '_' or ch == '[' or ch == '!' or
                ch == '`' or ch == '<' or ch == '\\' or ch == '\n') break;
            te += 1;
        }
        if (te > pos) {
            try inlines.append(allocator, .{ .text = .{ .content = input[pos..te] } });
            pos = te;
        } else if (c == '\n') {
            var is_hard = false;
            if (inlines.items.len > 0) {
                switch (inlines.items[inlines.items.len - 1]) {
                    .text => |*txt| {
                        if (txt.content.len >= 2 and
                            txt.content[txt.content.len - 1] == ' ' and
                            txt.content[txt.content.len - 2] == ' ')
                        {
                            is_hard = true;
                            txt.content = mem.trimRight(u8, txt.content, " ");
                        }
                    },
                    else => {},
                }
            }
            if (is_hard) {
                try inlines.append(allocator, .{ .hard_break = .{} });
            } else {
                try inlines.append(allocator, .{ .soft_break = .{} });
            }
            pos += 1;
        } else {
            try inlines.append(allocator, .{ .text = .{ .content = input[pos .. pos + 1] } });
            pos += 1;
        }
    }

    try processEmphasis(allocator, &inlines, &delimiters);
    return inlines;
}

fn flattenInlineText(allocator: Allocator, input: []const u8, ref_map: ?*const RefMap) Allocator.Error![]const u8 {
    _ = ref_map;
    return allocator.dupe(u8, input);
}

fn flattenInline(allocator: Allocator, buf: *std.ArrayList(u8), item: AST.Inline) !void {
    switch (item) {
        .text => |t| try buf.appendSlice(allocator, t.content),
        .code_span => |cs| try buf.appendSlice(allocator, cs.content),
        .emphasis => |e| {
            for (e.children.items) |child| try flattenInline(allocator, buf, child);
        },
        .strong => |s| {
            for (s.children.items) |child| try flattenInline(allocator, buf, child);
        },
        .link => |l| {
            for (l.children.items) |child| try flattenInline(allocator, buf, child);
        },
        .image => |img| try buf.appendSlice(allocator, img.alt_text),
        .soft_break => try buf.appendSlice(allocator, "\n"),
        .hard_break => {},
        else => {},
    }
}

fn tryParseHtmlTag(input: []const u8, pos: usize) ?usize {
    if (pos >= input.len or input[pos] != '<') return null;
    if (pos + 1 >= input.len) return null;
    const next = input[pos + 1];
    if ((next >= 'a' and next <= 'z') or (next >= 'A' and next <= 'Z')) {
        var i = pos + 2;
        while (i < input.len and ((input[i] >= 'a' and input[i] <= 'z') or
            (input[i] >= 'A' and input[i] <= 'Z') or
            (input[i] >= '0' and input[i] <= '9') or input[i] == '-'))
        {
            i += 1;
        }
        while (i < input.len and input[i] != '>') {
            if (input[i] == '\n') return null;
            i += 1;
        }
        if (i < input.len and input[i] == '>') return i + 1;
        return null;
    }
    if (next == '/') {
        var i = pos + 2;
        if (i >= input.len or !((input[i] >= 'a' and input[i] <= 'z') or (input[i] >= 'A' and input[i] <= 'Z'))) return null;
        while (i < input.len and ((input[i] >= 'a' and input[i] <= 'z') or
            (input[i] >= 'A' and input[i] <= 'Z') or
            (input[i] >= '0' and input[i] <= '9') or input[i] == '-'))
        {
            i += 1;
        }
        while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
        if (i < input.len and input[i] == '>') return i + 1;
        return null;
    }
    if (pos + 3 < input.len and input[pos + 1] == '!' and input[pos + 2] == '-' and input[pos + 3] == '-') {
        var i = pos + 4;
        while (i + 2 < input.len) {
            if (input[i] == '-' and input[i + 1] == '-' and input[i + 2] == '>') return i + 3;
            i += 1;
        }
        return null;
    }
    if (next == '?') {
        var i = pos + 2;
        while (i + 1 < input.len) {
            if (input[i] == '?' and input[i + 1] == '>') return i + 2;
            i += 1;
        }
        return null;
    }
    if (pos + 8 < input.len and mem.startsWith(u8, input[pos..], "<![CDATA[")) {
        var i = pos + 9;
        while (i + 2 < input.len) {
            if (input[i] == ']' and input[i + 1] == ']' and input[i + 2] == '>') return i + 3;
            i += 1;
        }
        return null;
    }
    if (next == '!' and pos + 2 < input.len and ((input[pos + 2] >= 'a' and input[pos + 2] <= 'z') or (input[pos + 2] >= 'A' and input[pos + 2] <= 'Z'))) {
        var i = pos + 3;
        while (i < input.len and input[i] != '>') i += 1;
        if (i < input.len) return i + 1;
        return null;
    }
    return null;
}

fn tryParseImageRefLink(allocator: Allocator, input: []const u8, start: usize, rm: *const RefMap) ?struct {
    inline_node: AST.Inline,
    end: usize,
} {
    if (start >= input.len or input[start] != '!' or start + 1 >= input.len or input[start + 1] != '[') return null;
    var be: usize = start + 2;
    while (be < input.len and input[be] != ']') {
        if (input[be] == '\\' and be + 1 < input.len) {
            be += 2;
        } else {
            be += 1;
        }
    }
    if (be >= input.len) return null;
    const alt_text = input[start + 2 .. be];

    if (be + 1 < input.len and input[be + 1] == '[') {
        var le: usize = be + 2;
        while (le < input.len and input[le] != ']') : (le += 1) {}
        if (le < input.len) {
            const ref_label = input[be + 2 .. le];
            const norm = normalizeLabel(allocator, ref_label) catch return null;
            defer allocator.free(norm);
            if (rm.get(norm)) |dest| {
                const url_copy = allocator.dupe(u8, dest.url) catch return null;
                const title_copy: ?[]const u8 = if (dest.title) |t| (allocator.dupe(u8, t) catch return null) else null;
                return .{ .inline_node = .{ .image = .{
                    .alt_text = alt_text,
                    .destination = .{ .url = url_copy, .title = title_copy },
                    .link_type = .reference,
                } }, .end = le + 1 };
            }
        }
    }

    if (be + 2 < input.len and input[be + 1] == '[' and input[be + 2] == ']') {
        const norm = normalizeLabel(allocator, alt_text) catch return null;
        defer allocator.free(norm);
        if (rm.get(norm)) |dest| {
            const url_copy = allocator.dupe(u8, dest.url) catch return null;
            const title_copy: ?[]const u8 = if (dest.title) |t| (allocator.dupe(u8, t) catch return null) else null;
            return .{ .inline_node = .{ .image = .{
                .alt_text = alt_text,
                .destination = .{ .url = url_copy, .title = title_copy },
                .link_type = .collapsed,
            } }, .end = be + 3 };
        }
    }

    {
        const norm = normalizeLabel(allocator, alt_text) catch return null;
        defer allocator.free(norm);
        if (rm.get(norm)) |dest| {
            const url_copy = allocator.dupe(u8, dest.url) catch return null;
            const title_copy: ?[]const u8 = if (dest.title) |t| (allocator.dupe(u8, t) catch return null) else null;
            return .{ .inline_node = .{ .image = .{
                .alt_text = alt_text,
                .destination = .{ .url = url_copy, .title = title_copy },
                .link_type = .shortcut,
            } }, .end = be + 1 };
        }
    }

    return null;
}

/// CommonMark "process emphasis" algorithm (§6.4).
fn processEmphasis(allocator: Allocator, inlines: *std.ArrayList(AST.Inline), delimiters: *std.ArrayList(Delimiter)) !void {
    var closer_idx: usize = 0;
    while (closer_idx < delimiters.items.len) {
        var closer = &delimiters.items[closer_idx];
        if (!closer.active or !closer.can_close) {
            closer_idx += 1;
            continue;
        }

        var found_opener = false;
        var opener_idx: usize = closer_idx;
        while (opener_idx > 0) {
            opener_idx -= 1;
            const opener = &delimiters.items[opener_idx];
            if (!opener.active or !opener.can_open or opener.marker != closer.marker) continue;

            if ((opener.can_close or closer.can_open) and
                (opener.orig_count + closer.orig_count) % 3 == 0 and
                opener.orig_count % 3 != 0 and closer.orig_count % 3 != 0)
            {
                continue;
            }

            found_opener = true;
            const use_count: usize = if (closer.count >= 2 and opener.count >= 2) 2 else 1;

            if (use_count == 2) {
                var strong = AST.Strong.init(allocator, closer.marker);
                const open_inline = opener.inline_idx;
                const close_inline = closer.inline_idx;
                const children_start = open_inline + 1;
                const children_end = close_inline;
                var ci = children_start;
                while (ci < children_end) {
                    try strong.children.append(allocator, inlines.items[ci]);
                    ci += 1;
                }

                opener.count -= 2;
                closer.count -= 2;

                if (opener.count > 0) {
                    const old_content = inlines.items[open_inline].text.content;
                    inlines.items[open_inline] = .{ .text = .{ .content = old_content[0..opener.count] } };
                }

                if (closer.count > 0) {
                    const old_content = inlines.items[close_inline].text.content;
                    inlines.items[close_inline] = .{ .text = .{ .content = old_content[0..closer.count] } };
                }

                const remove_start = if (opener.count > 0) open_inline + 1 else open_inline;
                const remove_end = if (closer.count > 0) close_inline else close_inline + 1;

                if (remove_end > remove_start) {
                    const removed = remove_end - remove_start;
                    inlines.items[remove_start] = .{ .strong = strong };
                    if (removed > 1) {
                        var si = remove_start + 1;
                        while (si + removed - 1 < inlines.items.len) {
                            inlines.items[si] = inlines.items[si + removed - 1];
                            si += 1;
                        }
                        inlines.items.len -= removed - 1;
                    }
                    for (delimiters.items) |*d| {
                        if (d.inline_idx > remove_start and d.inline_idx < remove_end) {
                            d.active = false;
                        } else if (d.inline_idx >= remove_end) {
                            d.inline_idx -= removed - 1;
                        }
                    }
                    closer = &delimiters.items[closer_idx];
                }

                var di = opener_idx + 1;
                while (di < closer_idx) {
                    delimiters.items[di].active = false;
                    di += 1;
                }

                if (opener.count == 0) opener.active = false;
                if (closer.count == 0) {
                    closer.active = false;
                    closer_idx += 1;
                }
            } else {
                var emph = AST.Emphasis.init(allocator, closer.marker);
                const open_inline = opener.inline_idx;
                const close_inline = closer.inline_idx;

                var ci = open_inline + 1;
                while (ci < close_inline) {
                    try emph.children.append(allocator, inlines.items[ci]);
                    ci += 1;
                }

                opener.count -= 1;
                closer.count -= 1;

                if (opener.count > 0) {
                    const old_content = inlines.items[open_inline].text.content;
                    inlines.items[open_inline] = .{ .text = .{ .content = old_content[0..opener.count] } };
                }

                if (closer.count > 0) {
                    const old_content = inlines.items[close_inline].text.content;
                    inlines.items[close_inline] = .{ .text = .{ .content = old_content[0..closer.count] } };
                }

                const remove_start = if (opener.count > 0) open_inline + 1 else open_inline;
                const remove_end = if (closer.count > 0) close_inline else close_inline + 1;

                if (remove_end > remove_start) {
                    const removed = remove_end - remove_start;
                    inlines.items[remove_start] = .{ .emphasis = emph };
                    if (removed > 1) {
                        var si = remove_start + 1;
                        while (si + removed - 1 < inlines.items.len) {
                            inlines.items[si] = inlines.items[si + removed - 1];
                            si += 1;
                        }
                        inlines.items.len -= removed - 1;
                    }
                    for (delimiters.items) |*d| {
                        if (d.inline_idx > remove_start and d.inline_idx < remove_end) {
                            d.active = false;
                        } else if (d.inline_idx >= remove_end) {
                            d.inline_idx -= removed - 1;
                        }
                    }
                    closer = &delimiters.items[closer_idx];
                }

                var di = opener_idx + 1;
                while (di < closer_idx) {
                    delimiters.items[di].active = false;
                    di += 1;
                }

                if (opener.count == 0) opener.active = false;
                if (closer.count == 0) {
                    closer.active = false;
                    closer_idx += 1;
                }
            }
            break;
        }

        if (!found_opener) {
            if (!closer.can_open) {
                closer.active = false;
            }
            closer_idx += 1;
        }
    }

    // Remove empty text nodes left by consumed delimiters
    var write: usize = 0;
    for (inlines.items) |item| {
        const skip = switch (item) {
            .text => |t| t.content.len == 0,
            else => false,
        };
        if (!skip) {
            inlines.items[write] = item;
            write += 1;
        }
    }
    inlines.items.len = write;
}

fn tryParseRefLink(allocator: Allocator, input: []const u8, start: usize, rm: *const RefMap) ?struct {
    inline_node: AST.Inline,
    end: usize,
} {
    if (start >= input.len or input[start] != '[') return null;

    var be: usize = start + 1;
    var bracket_depth: i32 = 0;
    while (be < input.len) {
        if (input[be] == '\\' and be + 1 < input.len) {
            be += 2;
        } else if (input[be] == '[') {
            bracket_depth += 1;
            be += 1;
        } else if (input[be] == ']') {
            if (bracket_depth == 0) break;
            bracket_depth -= 1;
            be += 1;
        } else {
            be += 1;
        }
    }
    if (be >= input.len) return null;
    const link_text = input[start + 1 .. be];

    if (be + 1 < input.len and input[be + 1] == '[') {
        var le: usize = be + 2;
        while (le < input.len and input[le] != ']') : (le += 1) {}
        if (le < input.len) {
            const ref_label = input[be + 2 .. le];
            const norm = normalizeLabel(allocator, ref_label) catch return null;
            defer allocator.free(norm);
            if (rm.get(norm)) |dest| {
                const url_copy = allocator.dupe(u8, dest.url) catch return null;
                const title_copy: ?[]const u8 = if (dest.title) |t| (allocator.dupe(u8, t) catch return null) else null;
                var link = AST.Link.init(allocator, .{ .url = url_copy, .title = title_copy }, .reference);
                var nested = parseInlineElements(allocator, link_text, rm) catch return null;
                defer nested.deinit(allocator);
                for (nested.items) |item| link.children.append(allocator, item) catch return null;
                return .{ .inline_node = .{ .link = link }, .end = le + 1 };
            }
        }
    }

    if (be + 2 < input.len and input[be + 1] == '[' and input[be + 2] == ']') {
        const norm = normalizeLabel(allocator, link_text) catch return null;
        defer allocator.free(norm);
        if (rm.get(norm)) |dest| {
            const url_copy = allocator.dupe(u8, dest.url) catch return null;
            const title_copy: ?[]const u8 = if (dest.title) |t| (allocator.dupe(u8, t) catch return null) else null;
            var link = AST.Link.init(allocator, .{ .url = url_copy, .title = title_copy }, .collapsed);
            var nested = parseInlineElements(allocator, link_text, rm) catch return null;
            defer nested.deinit(allocator);
            for (nested.items) |item| link.children.append(allocator, item) catch return null;
            return .{ .inline_node = .{ .link = link }, .end = be + 3 };
        }
    }

    {
        const norm = normalizeLabel(allocator, link_text) catch return null;
        defer allocator.free(norm);
        if (rm.get(norm)) |dest| {
            const url_copy = allocator.dupe(u8, dest.url) catch return null;
            const title_copy: ?[]const u8 = if (dest.title) |t| (allocator.dupe(u8, t) catch return null) else null;
            var link = AST.Link.init(allocator, .{ .url = url_copy, .title = title_copy }, .shortcut);
            var nested = parseInlineElements(allocator, link_text, rm) catch return null;
            defer nested.deinit(allocator);
            for (nested.items) |item| link.children.append(allocator, item) catch return null;
            return .{ .inline_node = .{ .link = link }, .end = be + 1 };
        }
    }

    return null;
}

// ── Block parser ──────────────────────────────────────────────────────────────

const Self = @This();

pub fn init() Self {
    return Self{};
}

pub fn deinit(_: *Self, _: Allocator) void {}

fn appendInlines(allocator: Allocator, dest: *std.ArrayList(AST.Inline), content: []const u8, ref_map: ?*const RefMap) !void {
    var items = try parseInlineElements(allocator, content, ref_map);
    defer items.deinit(allocator);
    for (items.items) |item| try dest.append(allocator, item);
}

pub fn parseMarkdown(self: Self, allocator: Allocator, input: []const u8) !AST.Document {
    var ref_map = RefMap.init(allocator);
    defer {
        var it = ref_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*.url);
            if (entry.value_ptr.*.title) |t| allocator.free(t);
        }
        ref_map.deinit();
    }
    try collectLinkRefDefs(allocator, input, &ref_map);
    return self.parseMarkdownWithRefs(allocator, input, &ref_map);
}

fn collectLinkRefDefs(allocator: Allocator, input: []const u8, ref_map: *RefMap) !void {
    var lines_list = std.ArrayList([]const u8){};
    defer lines_list.deinit(allocator);
    {
        var it = mem.splitScalar(u8, input, '\n');
        while (it.next()) |raw| {
            const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
            try lines_list.append(allocator, line);
        }
    }
    const lines = lines_list.items;
    var i: usize = 0;

    // Skip frontmatter
    if (lines.len > 0) {
        const fl = trimLine(lines[0]);
        if (mem.eql(u8, fl, "---") or mem.eql(u8, fl, "+++") or mem.eql(u8, fl, "%%%")) {
            var fi: usize = 1;
            while (fi < lines.len) {
                const tl = trimLine(lines[fi]);
                fi += 1;
                if (mem.eql(u8, tl, "---") or mem.eql(u8, tl, "+++") or mem.eql(u8, tl, "%%%")) {
                    i = fi;
                    break;
                }
            }
        }
    }

    while (i < lines.len) {
        const line = lines[i];
        const trimmed = mem.trimLeft(u8, line, " ");
        if (trimmed.len == 0 or trimmed[0] != '[') {
            i += 1;
            continue;
        }

        var candidate = std.ArrayList(u8){};
        defer candidate.deinit(allocator);
        try candidate.appendSlice(allocator, line);
        var lines_consumed: usize = 1;
        var j = i + 1;
        while (j < lines.len and lines_consumed < 4) : (j += 1) {
            const next = lines[j];
            if (trimLine(next).len == 0) break;
            try candidate.append(allocator, '\n');
            try candidate.appendSlice(allocator, next);
            lines_consumed += 1;
        }

        if (parseLinkRefDef(candidate.items)) |def| {
            const norm = try normalizeLabel(allocator, def.label);
            if (!ref_map.contains(norm)) {
                const url_dupe = try allocator.dupe(u8, def.url);
                const title_dupe: ?[]const u8 = if (def.title) |t| try allocator.dupe(u8, t) else null;
                try ref_map.put(norm, .{ .url = url_dupe, .title = title_dupe });
            } else {
                allocator.free(norm);
            }
        }
        i += 1;
    }
}

const ListParseConfig = struct {
    list_type: AST.ListType,
    marker: u8, // for bullet lists: -, *, +
    delimiter: u8, // for ordered lists: . or )
    start_num: u32, // for ordered lists: starting number
};

const ListParseResult = struct {
    list: AST.List,
    next_line: usize,
};

/// Parse a complete list (bullet or ordered) starting at line index `start`.
/// Collects multi-line items, handles continuation indentation, detects loose/tight,
/// and recursively parses each item's content as blocks.
fn parseList(
    allocator: Allocator,
    lines: []const []const u8,
    start: usize,
    ref_map: *const RefMap,
    config: ListParseConfig,
) anyerror!ListParseResult {
    var list = AST.List.init(allocator, config.list_type);
    if (config.list_type == .ordered) {
        list.start = config.start_num;
    }

    var i = start;
    var had_blank_between_items = false;
    var any_item_has_blank = false;

    while (i < lines.len) {
        // Try to parse a list marker on this line
        var content_col: usize = undefined;
        var item_first_line: []const u8 = undefined;
        var is_blank_item = false;

        if (config.list_type == .unordered) {
            const info = bulletListContentColumn(lines[i]) orelse break;
            if (info.marker != config.marker) break;
            content_col = info.col;
            // Extract content after marker
            item_first_line = extractFirstLineContent(lines[i], content_col);
            is_blank_item = trimLine(item_first_line).len == 0;
        } else {
            const info = orderedListContentColumn(lines[i]) orelse break;
            if (info.delimiter != config.delimiter) break;
            content_col = info.col;
            item_first_line = extractFirstLineContent(lines[i], content_col);
            is_blank_item = trimLine(item_first_line).len == 0;
        }

        // Collect all lines belonging to this list item
        var item_buf = std.ArrayList(u8){};
        // Add the first line's content
        try item_buf.appendSlice(allocator, item_first_line);
        i += 1;

        var saw_blank_in_item = false;
        var consecutive_blanks: usize = 0;
        var pending_blanks: usize = 0;

        // Collect continuation lines
        while (i < lines.len) {
            const line = lines[i];

            if (isBlankLine(line)) {
                consecutive_blanks += 1;
                pending_blanks += 1;
                // For blank-start items, a blank line after the empty first line ends the item
                // (at most one blank line allowed for blank-start items to pick up content)
                if (is_blank_item and consecutive_blanks >= 1 and trimLine(item_buf.items).len == 0) break;
                i += 1;
                continue;
            }
            consecutive_blanks = 0;

            // Check if this line starts a new list item at the same level
            var is_new_sibling = false;
            if (config.list_type == .unordered) {
                if (bulletListContentColumn(line)) |new_info| {
                    if (new_info.marker == config.marker and countLeadingSpaces(line) < content_col) {
                        is_new_sibling = true;
                    } else if (new_info.marker != config.marker and countLeadingSpaces(line) < content_col) {
                        break; // Different marker, different list
                    }
                }
            } else {
                if (orderedListContentColumn(line)) |new_info| {
                    if (new_info.delimiter == config.delimiter and
                        countLeadingSpaces(line) < content_col)
                    {
                        is_new_sibling = true;
                    }
                }
            }
            if (is_new_sibling) break;

            // Check if the line is indented to the content column
            const leading = countLeadingSpaces(line);
            if (leading >= content_col) {
                // Continuation line: commit pending blank lines and strip indentation
                if (pending_blanks > 0) {
                    saw_blank_in_item = true;
                    var b: usize = 0;
                    while (b < pending_blanks) : (b += 1) {
                        try item_buf.append(allocator, '\n');
                    }
                    pending_blanks = 0;
                }
                const stripped = stripIndent(line, content_col);
                try item_buf.append(allocator, '\n');
                try item_buf.appendSlice(allocator, stripped);
                i += 1;
            } else {
                // Not indented enough — this line doesn't belong to the item.
                // But check for lazy continuation (paragraph continuation):
                if (pending_blanks > 0) break; // After a blank line, must be indented
                // Lazy continuation only for paragraph text
                const lt = trimLine(line);
                if (lt.len == 0) break;
                // If the line starts any block-level construct, it's not lazy
                if (bulletListContentColumn(line) != null) break;
                if (orderedListContentColumn(line) != null) break;
                if (lt[0] == '#') break;
                if (lt[0] == '>') break;
                if (isThematicBreak(lt)) break;
                if (parsers.tryFenceStart(line) != null) break;
                // Lazy paragraph continuation
                try item_buf.append(allocator, '\n');
                try item_buf.appendSlice(allocator, lt);
                i += 1;
            }
        }

        // Track whether there were pending blank lines at the end of this item
        // (they might be between this item and the next)
        const had_pending_blanks = pending_blanks > 0;

        // Parse the item's collected content as blocks
        var item = AST.ListItem.init(allocator);
        const item_content = try item_buf.toOwnedSlice(allocator);

        if (trimLine(item_content).len > 0) {
            var inner_parser = init();
            var inner_doc = try inner_parser.parseMarkdownWithRefs(allocator, item_content, ref_map);
            for (inner_doc.children.items) |block| {
                try item.children.append(allocator, block);
            }
            inner_doc.children = std.ArrayList(AST.Block){};
        }

        // Determine if this item has blank lines separating block children.
        // Blank lines inside fenced code blocks or nested lists don't count.
        if (saw_blank_in_item) {
            const is_single_code = item.children.items.len == 1 and
                (item.children.items[0] == .code_block or item.children.items[0] == .fenced_code_block);
            if (!is_single_code) {
                // Check if blank lines were between direct block children (not inside nested lists).
                var direct_para_count: usize = 0;
                var direct_list_count: usize = 0;
                var has_non_list_non_para_blocks = false;
                for (item.children.items) |child| {
                    switch (child) {
                        .paragraph => direct_para_count += 1,
                        .list => direct_list_count += 1,
                        else => has_non_list_non_para_blocks = true,
                    }
                }
                // Multiple paragraphs → blank lines between them
                if (direct_para_count > 1) {
                    any_item_has_blank = true;
                }
                // Paragraph + non-list block → blank lines between them
                else if (direct_para_count >= 1 and has_non_list_non_para_blocks) {
                    any_item_has_blank = true;
                }
                // Single paragraph + only lists: blank lines are inside nested lists, don't count
                // UNLESS the raw content had blank lines that didn't go into nested lists
                // (e.g. link ref defs that were consumed)
                else if (direct_para_count == 1 and direct_list_count == 0 and !has_non_list_non_para_blocks) {
                    // Item has one paragraph but had blank lines → something was consumed (link ref def)
                    any_item_has_blank = true;
                }
                // No blocks at all → empty item with blank
                else if (item.children.items.len == 0) {
                    any_item_has_blank = true;
                }
            }
        }

        try list.items.append(allocator, item);

        // Skip blank lines between items
        var blanks_between: usize = 0;
        while (i < lines.len and isBlankLine(lines[i])) {
            blanks_between += 1;
            i += 1;
        }
        const total_blanks_between = blanks_between + @as(usize, if (had_pending_blanks) 1 else 0);
        if (total_blanks_between > 0 and i < lines.len) {
            // Check if the next line starts a new item in this list
            var is_next_item = false;
            if (config.list_type == .unordered) {
                if (bulletListContentColumn(lines[i])) |new_info| {
                    is_next_item = new_info.marker == config.marker;
                }
            } else {
                if (orderedListContentColumn(lines[i])) |new_info| {
                    is_next_item = new_info.delimiter == config.delimiter;
                }
            }
            if (!is_next_item) break; // blank line followed by non-list-item ends the list
            had_blank_between_items = true;
        }
    }

    // A list is loose if there are blank lines between items OR
    // any item contains blank lines separating block children
    list.tight = !had_blank_between_items and !any_item_has_blank;

    return .{ .list = list, .next_line = i };
}

/// Extract the content portion of a list item's first line, starting at content_col.
fn extractFirstLineContent(line: []const u8, content_col: usize) []const u8 {
    var pos: usize = 0;
    var col: usize = 0;
    while (pos < line.len and col < content_col) {
        if (line[pos] == '\t') {
            col += 4 - (col % 4);
        } else {
            col += 1;
        }
        pos += 1;
    }
    if (pos >= line.len) return "";
    return line[pos..];
}

/// Strip `n` columns of indentation from a line.
fn stripIndent(line: []const u8, n: usize) []const u8 {
    var pos: usize = 0;
    var col: usize = 0;
    while (pos < line.len and col < n) {
        if (line[pos] == '\t') {
            col += 4 - (col % 4);
        } else if (line[pos] == ' ') {
            col += 1;
        } else break;
        pos += 1;
    }
    return line[pos..];
}

fn parseMarkdownWithRefs(_: Self, allocator: Allocator, input: []const u8, ref_map: *const RefMap) !AST.Document {
    var doc = AST.Document.init(allocator);

    var lines_list = std.ArrayList([]const u8){};
    defer lines_list.deinit(allocator);
    {
        var it = mem.splitScalar(u8, input, '\n');
        while (it.next()) |raw| {
            const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
            try lines_list.append(allocator, line);
        }
    }
    const lines = lines_list.items;
    var i: usize = 0;

    // Skip frontmatter
    if (lines.len > 0) {
        const fl = trimLine(lines[0]);
        if (mem.eql(u8, fl, "---") or mem.eql(u8, fl, "+++") or mem.eql(u8, fl, "%%%")) {
            var fi: usize = 1;
            var found_close = false;
            while (fi < lines.len) {
                const tl = trimLine(lines[fi]);
                fi += 1;
                if (mem.eql(u8, tl, "---") or mem.eql(u8, tl, "+++") or mem.eql(u8, tl, "%%%")) {
                    found_close = true;
                    break;
                }
            }
            if (found_close) i = fi;
        }
    }

    while (i < lines.len) {
        const raw = lines[i];
        const t = trimLine(raw);

        if (t.len == 0) {
            i += 1;
            continue;
        }

        // Link reference definition (already collected; skip)
        if (isLinkRefDefLine(raw)) {
            i += 1;
            while (i < lines.len and !isBlankLine(lines[i]) and
                !isStandaloneBlockStart(allocator, lines[i]))
            {
                break;
            }
            continue;
        }

        // ATX heading
        if (parsers.tryAtxHeading(allocator, raw)) |h| {
            var heading = AST.Heading.init(allocator, h.level);
            try appendInlines(allocator, &heading.children, h.content, ref_map);
            try doc.children.append(allocator, .{ .heading = heading });
            i += 1;
            continue;
        }

        // Thematic break
        if (isThematicBreak(t)) {
            try doc.children.append(allocator, .{ .thematic_break = .{ .char = t[0] } });
            i += 1;
            continue;
        }

        // Indented code block
        if (parsers.tryIndentedCode(raw)) |_| {
            var buf = std.ArrayList(u8){};
            while (i < lines.len) {
                if (trimLine(lines[i]).len == 0) {
                    var peek = i + 1;
                    while (peek < lines.len and trimLine(lines[peek]).len == 0) peek += 1;
                    if (peek >= lines.len or parsers.tryIndentedCode(lines[peek]) == null) break;
                    try buf.append(allocator, '\n');
                    i += 1;
                    continue;
                }
                const stripped = parsers.tryIndentedCode(lines[i]) orelse break;
                if (buf.items.len > 0) try buf.append(allocator, '\n');
                try buf.appendSlice(allocator, stripped);
                i += 1;
            }
            try doc.children.append(allocator, .{ .code_block = .{
                .content = try buf.toOwnedSlice(allocator),
            } });
            continue;
        }

        // Fenced code block
        if (parsers.tryFenceStart(raw)) |fence| {
            i += 1;
            var buf = std.ArrayList(u8){};
            while (i < lines.len) {
                if (parsers.isFenceEnd(lines[i], fence)) {
                    i += 1;
                    break;
                }
                if (buf.items.len > 0) try buf.append(allocator, '\n');
                try buf.appendSlice(allocator, lines[i]);
                i += 1;
            }
            const lang: ?[]const u8 = if (fence.info.len > 0) fence.info else null;
            try doc.children.append(allocator, .{ .fenced_code_block = AST.FencedCodeBlock.init(
                try buf.toOwnedSlice(allocator),
                lang,
                fence.char,
                fence.len,
            ) });
            continue;
        }

        // Blockquote
        if (parsers.tryBlockquoteLine(allocator, raw)) |_| {
            var bq_buf = std.ArrayList(u8){};
            while (i < lines.len) {
                if (parsers.tryBlockquoteLine(allocator, lines[i])) |content_line| {
                    if (bq_buf.items.len > 0) try bq_buf.append(allocator, '\n');
                    try bq_buf.appendSlice(allocator, content_line);
                    i += 1;
                } else if (!isBlankLine(lines[i])) {
                    if (bq_buf.items.len > 0) try bq_buf.append(allocator, '\n');
                    try bq_buf.appendSlice(allocator, lines[i]);
                    i += 1;
                } else {
                    break;
                }
            }
            const bq_str = try bq_buf.toOwnedSlice(allocator);
            var inner = init();
            var inner_doc = try inner.parseMarkdownWithRefs(allocator, bq_str, ref_map);

            var bq = AST.Blockquote.init(allocator);
            for (inner_doc.children.items) |block| try bq.children.append(allocator, block);
            inner_doc.children = std.ArrayList(AST.Block){};
            try doc.children.append(allocator, .{ .blockquote = bq });
            continue;
        }

        // Unordered list
        if (bulletListContentColumn(raw)) |first_info| {
            const result = try parseList(allocator, lines, i, ref_map, .{
                .list_type = .unordered,
                .marker = first_info.marker,
                .delimiter = 0,
                .start_num = 0,
            });
            try doc.children.append(allocator, .{ .list = result.list });
            i = result.next_line;
            continue;
        }

        // Ordered list
        if (orderedListContentColumn(raw)) |first_info| {
            const result = try parseList(allocator, lines, i, ref_map, .{
                .list_type = .ordered,
                .marker = 0,
                .delimiter = first_info.delimiter,
                .start_num = first_info.num,
            });
            try doc.children.append(allocator, .{ .list = result.list });
            i = result.next_line;
            continue;
        }

        // Footnote definition
        if (parsers.tryFootnoteDef(allocator, t)) |fd| {
            var fn_def = AST.FootnoteDefinition.init(allocator, fd.label);
            var para = AST.Paragraph.init(allocator);
            try appendInlines(allocator, &para.children, fd.content, ref_map);
            try fn_def.children.append(allocator, .{ .paragraph = para });
            try doc.children.append(allocator, .{ .footnote_definition = fn_def });
            i += 1;
            continue;
        }

        // Paragraph (possibly a setext heading)
        {
            var is_first = true;
            var para_buf = std.ArrayList(u8){};
            // var line_count: usize = 0;
            // _ = line_count;

            while (i < lines.len) {
                const lr = lines[i];
                const lt = trimLine(lr);

                if (lt.len == 0) break;
                if (!is_first and (isSetextEqLine(lt) or isSetextDashLine(lt))) break;
                if (!is_first and isParaBreak(allocator, lt, lr)) break;

                const next_setext = blk: {
                    if (i + 1 >= lines.len) break :blk false;
                    const nt = trimLine(lines[i + 1]);
                    break :blk isSetextEqLine(nt) or isSetextDashLine(nt);
                };

                if (!is_first) {
                    try para_buf.append(allocator, '\n');
                }
                is_first = false;

                const lr_nocr = mem.trimRight(u8, lr, "\r");
                const has_hard_break = lr_nocr.len >= 2 and
                    lr_nocr[lr_nocr.len - 1] == ' ' and
                    lr_nocr[lr_nocr.len - 2] == ' ';

                if (has_hard_break) {
                    try para_buf.appendSlice(allocator, mem.trimRight(u8, lt, " "));
                    try para_buf.appendSlice(allocator, "  ");
                } else {
                    try para_buf.appendSlice(allocator, lt);
                }

                i += 1;
                if (next_setext) break;
            }

            var para = AST.Paragraph.init(allocator);
            if (para_buf.items.len > 0) {
                const para_content = try para_buf.toOwnedSlice(allocator);
                try appendInlines(allocator, &para.children, para_content, ref_map);
            }

            // Setext heading?
            if (i < lines.len and para.children.items.len > 0) {
                const st = trimLine(lines[i]);
                if (isSetextEqLine(st) or isSetextDashLine(st)) {
                    const level: u8 = if (isSetextEqLine(st)) 1 else 2;
                    var heading = AST.Heading.init(allocator, level);
                    for (para.children.items) |item| try heading.children.append(allocator, item);
                    para.children.clearRetainingCapacity();
                    para.deinit(allocator);
                    try doc.children.append(allocator, .{ .heading = heading });
                    i += 1;
                    continue;
                }
            }

            if (para.children.items.len > 0) {
                try doc.children.append(allocator, .{ .paragraph = para });
            } else {
                para.deinit(allocator);
            }
        }
    }

    return doc;
}

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
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = init();
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
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = init();
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
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = init();
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
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = init();
    var doc = try p.parseMarkdown(alloc, "line one\nline two\n");
    defer doc.deinit(alloc);
    try tst.expect(doc.children.items.len == 1);
    try tst.expect(doc.children.items[0] == .paragraph);
    const children = doc.children.items[0].paragraph.children.items;
    try tst.expect(children.len == 3);
    try tst.expect(children[1] == .soft_break);
}

test "indented code block" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = init();
    var doc = try p.parseMarkdown(alloc, "    code here\n");
    defer doc.deinit(alloc);
    try tst.expect(doc.children.items.len == 1);
    try tst.expect(doc.children.items[0] == .code_block);
}

test "fenced code block" {
    try ok("```\ncode\n```\n");
    try ok("~~~zig\ncode\n~~~\n");
    {
        var arena = std.heap.ArenaAllocator.init(tst.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var p = init();
        var doc = try p.parseMarkdown(alloc, "```zig\nconst x = 1;\n```\n");
        defer doc.deinit(alloc);
        try tst.expect(doc.children.items.len == 1);
        try tst.expect(doc.children.items[0] == .fenced_code_block);
        try tst.expectEqualStrings("zig", doc.children.items[0].fenced_code_block.language.?);
    }
}

test "list grouping" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = init();
    var doc = try p.parseMarkdown(alloc, "- item1\n- item2\n- item3\n");
    defer doc.deinit(alloc);
    try tst.expect(doc.children.items.len == 1);
    try tst.expect(doc.children.items[0] == .list);
    try tst.expectEqual(@as(usize, 3), doc.children.items[0].list.items.items.len);
    try tst.expect(doc.children.items[0].list.tight);
}

test "loose list" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = init();
    var doc = try p.parseMarkdown(alloc, "- item1\n\n- item2\n");
    defer doc.deinit(alloc);
    try tst.expect(doc.children.items[0] == .list);
    try tst.expect(!doc.children.items[0].list.tight);
}

test "ordered list" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = init();
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
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = init();
    var doc = try p.parseMarkdown(alloc, "\\*not emphasis\\*\n");
    defer doc.deinit(alloc);
    try tst.expect(doc.children.items.len == 1);
    try tst.expect(doc.children.items[0] == .paragraph);
}

test "code span" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = init();
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
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = init();
    var doc = try p.parseMarkdown(alloc, "<https://example.com>\n");
    defer doc.deinit(alloc);
    const para = doc.children.items[0].paragraph;
    try tst.expect(para.children.items[0] == .autolink);
    try tst.expect(!para.children.items[0].autolink.is_email);
}

test "image" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try ok("![alt](image.png)\n");
    var p = init();
    var doc = try p.parseMarkdown(alloc, "![alt text](img.png)\n");
    defer doc.deinit(alloc);
    const para = doc.children.items[0].paragraph;
    try tst.expect(para.children.items[0] == .image);
    try tst.expectEqualStrings("alt text", para.children.items[0].image.alt_text);
}

test {
    tst.refAllDecls(@This());
}
