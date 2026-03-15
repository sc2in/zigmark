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
//! the returned AST point into `input` or into owned buffers allocated
//! with the supplied allocator.  Calling `doc.deinit(allocator)` frees
//! every allocation the parser made.
//!
//! Block-level recognition is driven by the combinators and convenience
//! wrappers in the public `parsers` namespace.  Inline-level parsing uses
//! a hand-written state machine (CommonMark delimiter algorithm) because
//! emphasis nesting cannot be expressed as a pure combinator.
const std = @import("std");
const Allocator = std.mem.Allocator;
const tst = std.testing;
const mem = std.mem;
const unicode = std.unicode;

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
    pub const FenceInfo = struct { char: u8, len: usize, info: []const u8, indent: usize = 0 };

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
        alphanumeric,          mecha.ascii.char('.'), mecha.ascii.char('/'),
        mecha.ascii.char(':'), mecha.ascii.char('?'), mecha.ascii.char('='),
        mecha.ascii.char('&'), mecha.ascii.char('#'), mecha.ascii.char('-'),
        mecha.ascii.char('_'), mecha.ascii.char('~'), mecha.ascii.char('%'),
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

    pub const atx_heading = mecha.oneOf(.{
        mecha.combine(.{
            hash.many(.{ .collect = false, .min = 1, .max = 6 }),
            space,
            mecha.rest.asStr(),
        }).map(struct {
            fn f(r: anytype) HeadingResult {
                return .{ .level = @intCast(r[0].len), .content = mem.trim(u8, r[2], " \t#") };
            }
        }.f),
        hash.many(.{ .collect = false, .min = 1, .max = 6 }).map(struct {
            fn f(r: anytype) HeadingResult {
                return .{ .level = @intCast(r.len), .content = "" };
            }
        }.f),
    });

    pub const bullet_list_item = mecha.combine(.{
        space.many(.{ .collect = false, .min = 0, .max = 3 }),
        mecha.oneOf(.{ dash, asterisk, plus }),
        space,
        mecha.rest.asStr(),
    }).map(struct {
        fn f(r: anytype) BulletListResult {
            return .{ .marker = r[1], .content = mem.trimLeft(u8, r[3], " \t") };
        }
    }.f);

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

    pub const blockquote_line = mecha.combine(.{
        mecha.oneOf(.{ space, tab }).many(.{ .collect = false, .min = 0 }),
        gt,
        space.opt(),
        mecha.rest.asStr(),
    }).map(struct {
        fn f(r: anytype) BlockquoteResult {
            return .{ .content = mem.trimRight(u8, r[3], " \t\n\r") };
        }
    }.f);

    pub const footnote_definition = mecha.combine(.{
        lbracket,                                                                             caret,
        mecha.many(mecha.oneOf(.{ letter, digit }), .{ .collect = false, .min = 1 }).asStr(), rbracket,
        colon,                                                                                space,
        mecha.rest.asStr(),
    }).map(struct {
        fn f(r: anytype) FootnoteDefResult {
            return .{ .label = r[2], .content = mem.trim(u8, r[6], " \t\n\r") };
        }
    }.f);

    // ── Convenience wrappers ─────────────────────────────────────────────

    pub fn tryAtxHeading(allocator: Allocator, line: []const u8) ?HeadingResult {
        _ = allocator;
        // CommonMark: up to 3 spaces of leading indentation
        var pos: usize = 0;
        while (pos < line.len and pos < 3 and line[pos] == ' ') pos += 1;
        // Must not be 4+ spaces (that's an indented code block)
        if (pos < line.len and line[pos] == ' ') return null;
        if (pos >= line.len or line[pos] != '#') return null;
        // Count # characters (1-6)
        var level: u8 = 0;
        while (pos < line.len and line[pos] == '#') {
            level += 1;
            pos += 1;
        }
        if (level > 6) return null;
        // After the #'s, must be end of line or a space/tab
        if (pos < line.len and line[pos] != ' ' and line[pos] != '\t') return null;
        // Skip spaces after #
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
        var content = line[pos..];
        // Strip trailing spaces/tabs
        content = mem.trimRight(u8, content, " \t");
        // Strip optional closing sequence of #'s (only if preceded by space or empty)
        if (content.len > 0 and content[content.len - 1] == '#') {
            // Check if the trailing #'s are escaped
            var end = content.len;
            while (end > 0 and content[end - 1] == '#') end -= 1;
            // The # sequence must be preceded by a space (or be the entire content)
            if (end == 0 or content[end - 1] == ' ' or content[end - 1] == '\t') {
                // Check that the last # is not backslash-escaped
                var backslash_count: usize = 0;
                var check = end;
                while (check > 0 and content[check - 1] == '\\') {
                    backslash_count += 1;
                    check -= 1;
                }
                if (backslash_count % 2 == 0) {
                    // Not escaped; strip trailing #'s and spaces
                    content = mem.trimRight(u8, content[0..end], " \t");
                }
            }
        }
        return .{ .level = level, .content = content };
    }

    pub fn tryBulletListItem(allocator: Allocator, line: []const u8) ?BulletListResult {
        if (line.len < 2) return null;
        const result = bullet_list_item.parse(allocator, line) catch return null;
        return if (result.value == .ok) result.value.ok else null;
    }

    pub fn tryOrderedListItem(allocator: Allocator, line: []const u8) ?OrderedListResult {
        const result = ordered_list_item.parse(allocator, line) catch return null;
        return if (result.value == .ok) result.value.ok else null;
    }

    pub fn tryBlockquoteLine(allocator: Allocator, line: []const u8) ?[]const u8 {
        const t = mem.trimLeft(u8, line, " \t");
        if (t.len == 0 or t[0] != '>') return null;
        const result = blockquote_line.parse(allocator, line) catch return null;
        return switch (result.value) {
            .ok => |v| v.content,
            else => blk: {
                if (t.len == 1) break :blk @as([]const u8, "");
                if (t[1] == ' ' or t[1] == '\t') break :blk t[2..];
                break :blk t[1..];
            },
        };
    }

    pub fn tryFootnoteDef(allocator: Allocator, line: []const u8) ?FootnoteDefResult {
        const t = trimLine(line);
        if (!mem.startsWith(u8, t, "[^")) return null;
        const result = footnote_definition.parse(allocator, t) catch return null;
        return if (result.value == .ok) result.value.ok else null;
    }

    pub fn tryFenceStart(line: []const u8) ?FenceInfo {
        var s: usize = 0;
        while (s < 3 and s < line.len and line[s] == ' ') s += 1;
        if (s < line.len and s >= 1 and line[s] == ' ') {
            // Check if we got stopped because of 3-space limit, not because of non-space
            // Actually we stop at 3, so s can be 0,1,2,3. If s==3 and line[s]==' ' that's 4 spaces.
        }
        const t = line[s..];
        if (t.len < 3) return null;
        const c = t[0];
        if (c != '`' and c != '~') return null;
        var fl: usize = 0;
        while (fl < t.len and t[fl] == c) fl += 1;
        if (fl < 3) return null;
        const raw_info = mem.trim(u8, t[fl..], " \t\r");
        if (c == '`' and mem.indexOf(u8, raw_info, "`") != null) return null;
        // Info string is only the first word (up to first space)
        const info = blk: {
            if (mem.indexOfAny(u8, raw_info, " \t")) |space_idx| {
                break :blk raw_info[0..space_idx];
            }
            break :blk raw_info;
        };
        return .{ .char = c, .len = fl, .info = info, .indent = s };
    }

    pub fn isFenceEnd(line: []const u8, fence: FenceInfo) bool {
        // Closing fence: up to 3 spaces of indentation, then a run of fence chars >= fence length
        var leading: usize = 0;
        while (leading < line.len and leading < 3 and line[leading] == ' ') leading += 1;
        // If 4+ leading spaces, it's not a closing fence
        if (leading < line.len and leading >= 1 and line[leading] == ' ' and leading == 3) {
            // Actually check: is the 4th char also a space?
            // leading is at most 3, so if leading==3 and line[3] might be space
            // But we already stopped. The issue is: "    ```" has 4 spaces.
            // We count up to 3 spaces. If we have exactly 3, that's ok.
            // We need to also check line had 4+ spaces:
        }
        const t = mem.trimLeft(u8, line, " ");
        const total_leading = line.len - t.len;
        if (total_leading >= 4) return false;
        const trimmed = mem.trimRight(u8, t, " \t\r");
        if (trimmed.len == 0) return false;
        if (trimmed[0] != fence.char) return false;
        var n: usize = 0;
        while (n < trimmed.len and trimmed[n] == fence.char) n += 1;
        if (n < fence.len) return false;
        return mem.trim(u8, trimmed[n..], " \t").len == 0;
    }

    pub fn tryIndentedCode(line: []const u8) ?[]const u8 {
        // Check if leading whitespace produces >= 4 columns (tabs expand to next tab stop)
        var pos: usize = 0;
        var col: usize = 0;
        while (pos < line.len and col < 4 and (line[pos] == ' ' or line[pos] == '\t')) {
            if (line[pos] == '\t') {
                col += 4 - (col % 4);
            } else {
                col += 1;
            }
            pos += 1;
        }
        if (col < 4) return null;
        // If tab overshot past column 4, we need to emit virtual spaces
        // for the remaining columns. But since we return a slice, we can
        // only return from the current position. The content after stripping
        // 4 columns of indent is line[pos..], but if a tab expanded past 4
        // we can't add virtual spaces here. For the common case (tab at col 0
        // or spaces), this works. The virtual-space case is handled by the
        // caller's tab-aware stripping.
        return line[pos..];
    }
};

// ── Small shared helpers ─────────────────────────────────────────────────────

fn trimLine(line: []const u8) []const u8 {
    return mem.trim(u8, line, " \t\r");
}

fn isBlankLine(line: []const u8) bool {
    return trimLine(line).len == 0;
}

fn isThematicBreak(line: []const u8) bool {
    // CommonMark: up to 3 spaces of leading indentation, then 3+ of -, *, or _
    // with optional spaces between. 4+ leading spaces means not a thematic break.
    var leading: usize = 0;
    while (leading < line.len and line[leading] == ' ') leading += 1;
    if (leading >= 4) return false;
    const t = mem.trimRight(u8, line[leading..], " \t\r");
    if (t.len < 3) return false;
    const c = t[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var n: usize = 0;
    for (t) |ch| {
        if (ch == c) {
            n += 1;
        } else if (ch != ' ' and ch != '\t') return false;
    }
    return n >= 3;
}

fn isSetextEqLine(line: []const u8) bool {
    // Must have at most 3 leading spaces
    var leading: usize = 0;
    while (leading < line.len and line[leading] == ' ') leading += 1;
    if (leading >= 4) return false;
    const t = trimLine(line);
    if (t.len == 0) return false;
    for (t) |c| if (c != '=') return false;
    return true;
}

fn isSetextDashLine(line: []const u8) bool {
    // Must have at most 3 leading spaces
    var leading: usize = 0;
    while (leading < line.len and line[leading] == ' ') leading += 1;
    if (leading >= 4) return false;
    const t = trimLine(line);
    if (t.len == 0) return false;
    for (t) |c| if (c != '-') return false;
    return true;
}

fn isAsciiPunct(c: u8) bool {
    return (c >= '!' and c <= '/') or (c >= ':' and c <= '@') or
        (c >= '[' and c <= '`') or (c >= '{' and c <= '~');
}

// ── Tab-aware indentation helpers ────────────────────────────────────────────

const IndentResult = struct { pos: usize, col: usize };

/// Skip leading whitespace up to `max_col` columns, handling tabs (width 4).
fn skipIndent(line: []const u8, max_col: usize) IndentResult {
    var pos: usize = 0;
    var col: usize = 0;
    while (pos < line.len and col < max_col and (line[pos] == ' ' or line[pos] == '\t')) {
        if (line[pos] == '\t') {
            col += 4 - (col % 4);
        } else {
            col += 1;
        }
        pos += 1;
    }
    return .{ .pos = pos, .col = col };
}

fn countLeadingSpaces(line: []const u8) usize {
    return skipIndent(line, std.math.maxInt(usize)).col;
}

/// For a bullet list marker, compute the content column.
fn bulletListContentColumn(line: []const u8) ?struct { col: usize, marker: u8 } {
    const indent = skipIndent(line, 4);
    if (indent.col >= 4) return null;
    if (indent.pos >= line.len) return null;
    const marker = line[indent.pos];
    if (marker != '-' and marker != '*' and marker != '+') return null;
    var pos = indent.pos + 1;
    var col = indent.col + 1;
    if (pos >= line.len) return .{ .col = col + 1, .marker = marker };
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
    if (pos >= line.len) return .{ .col = marker_col + 1, .marker = marker };
    if (col - marker_col > 4) return .{ .col = marker_col + 1, .marker = marker };
    return .{ .col = col, .marker = marker };
}

/// For an ordered list marker, compute the content column.
fn orderedListContentColumn(line: []const u8) ?struct { col: usize, num: u32, delimiter: u8 } {
    const indent = skipIndent(line, 4);
    if (indent.col >= 4) return null;
    var pos = indent.pos;
    var col = indent.col;
    const digit_start = pos;
    while (pos < line.len and line[pos] >= '0' and line[pos] <= '9') pos += 1;
    const digit_count = pos - digit_start;
    if (digit_count == 0 or digit_count > 9) return null;
    col += digit_count;
    if (pos >= line.len) return null;
    const delimiter = line[pos];
    if (delimiter != '.' and delimiter != ')') return null;
    pos += 1;
    col += 1;
    const num = std.fmt.parseInt(u32, line[digit_start .. digit_start + digit_count], 10) catch return null;
    if (pos >= line.len) return .{ .col = col + 1, .num = num, .delimiter = delimiter };
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
    if (pos >= line.len) return .{ .col = marker_col + 1, .num = num, .delimiter = delimiter };
    if (col - marker_col > 4) return .{ .col = marker_col + 1, .num = num, .delimiter = delimiter };
    return .{ .col = col, .num = num, .delimiter = delimiter };
}

fn isBulletItemBlank(line: []const u8) bool {
    _ = bulletListContentColumn(line) orelse return false;
    const t = trimLine(line);
    return t.len == 1 and (t[0] == '-' or t[0] == '*' or t[0] == '+');
}

fn isOrderedItemBlank(line: []const u8) bool {
    const t = trimLine(line);
    if (t.len < 2) return false;
    var i: usize = 0;
    while (i < t.len and t[i] >= '0' and t[i] <= '9') i += 1;
    if (i == 0 or i >= t.len) return false;
    if (t[i] != '.' and t[i] != ')') return false;
    return i + 1 == t.len;
}

fn isParaBreak(allocator: Allocator, t: []const u8, raw: []const u8) bool {
    if (t.len == 0) return true;
    // ATX heading requires <= 3 leading spaces; use tryAtxHeading on raw line
    if (parsers.tryAtxHeading(allocator, raw) != null) return true;
    if (t[0] == '>') return true;
    if (isThematicBreak(raw)) return true;
    if (bulletListContentColumn(raw)) |_| {
        if (!isBulletItemBlank(raw)) return true;
    }
    if (orderedListContentColumn(raw)) |info| {
        if (info.num == 1 and !isOrderedItemBlank(raw)) return true;
    }
    if (parsers.tryFenceStart(raw) != null) return true;
    if (parsers.tryFootnoteDef(allocator, t) != null) return true;
    if (mem.indexOfScalar(u8, raw, '|')) |start| {
        if (start + 1 < raw.len)
            return true; // optional: more precise integration if you want
        // HTML block types 1-6 can interrupt a paragraph (type 7 cannot)
    }
    if (isHtmlBlockStart(t)) {
        const block_type = htmlBlockEndCondition(t);
        if (block_type != .type7) return true;
    }
    return false;
}

fn isLinkRefDefStart(line: []const u8) bool {
    var leading: usize = 0;
    for (line) |c| {
        if (c == ' ') {
            leading += 1;
        } else break;
    }
    if (leading >= 4) return false;
    const t = mem.trimLeft(u8, line, " ");
    if (t.len == 0 or t[0] != '[') return false;
    if (t.len > 1 and t[1] == '^') return false;
    var pos: usize = 1;
    while (pos < t.len) {
        if (t[pos] == '\\' and pos + 1 < t.len) {
            pos += 2;
        } else if (t[pos] == ']') return pos + 1 < t.len and t[pos + 1] == ':' else if (t[pos] == '[') return false else {
            pos += 1;
        }
    }
    return true;
}

fn isStandaloneBlockStart(allocator: Allocator, line: []const u8) bool {
    _ = allocator;
    const t = trimLine(line);
    if (t.len == 0) return true;
    if (t[0] == '#' or t[0] == '>') return true;
    if (isThematicBreak(line)) return true;
    if (bulletListContentColumn(line) != null) return true;
    if (orderedListContentColumn(line) != null) return true;
    if (parsers.tryFenceStart(line) != null) return true;
    if (isLinkRefDefStart(line)) return true;
    return false;
}

// ── Link reference definitions ────────────────────────────────────────────────

const RefMap = std.StringHashMap(struct { url: []const u8, title: ?[]const u8 });

/// Walk backwards from `pos` to find the start of the UTF-8 character.
fn utf8CharStart(input: []const u8, pos: usize) usize {
    var p = pos;
    while (p > 0 and (input[p] & 0xC0) == 0x80) p -= 1;
    return p;
}

/// Decode the UTF-8 codepoint starting at `pos`.
fn decodeUtf8At(input: []const u8, pos: usize) ?struct { cp: u21, len: u3 } {
    if (pos >= input.len) return null;
    const seq_len = unicode.utf8ByteSequenceLength(input[pos]) catch return null;
    if (pos + seq_len > input.len) return null;
    const cp = unicode.utf8Decode(input[pos..][0..seq_len]) catch return null;
    return .{ .cp = cp, .len = seq_len };
}

fn encodeUtf8(cp: u21, buf: *[4]u8) usize {
    if (cp < 0x80) {
        buf[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        buf[0] = @intCast(0xC0 | (cp >> 6));
        buf[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        buf[0] = @intCast(0xE0 | (cp >> 12));
        buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    } else {
        buf[0] = @intCast(0xF0 | (cp >> 18));
        buf[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        buf[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
}

/// Simple Unicode case folding (ASCII, Latin Extended, Greek, Cyrillic).
fn unicodeCaseFold(cp: u21) u21 {
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    if (cp >= 0x0391 and cp <= 0x03A1) return cp + 0x20;
    if (cp >= 0x03A3 and cp <= 0x03A9) return cp + 0x20;
    if (cp == 0x1E9E) return 0x00DF;
    if (cp >= 0x0410 and cp <= 0x042F) return cp + 0x20;
    if (cp >= 0x0100 and cp <= 0x017E and (cp & 1) == 0) return cp + 1;
    return cp;
}

/// Case-insensitive label normalization: collapse whitespace, Unicode casefold.
fn normalizeLabel(allocator: Allocator, label: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8){};
    var prev_ws = true;
    var i: usize = 0;
    while (i < label.len) {
        const c = label[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!prev_ws) try buf.append(allocator, ' ');
            prev_ws = true;
            i += 1;
        } else if (c < 0x80) {
            try buf.append(allocator, if (c >= 'A' and c <= 'Z') c + 32 else c);
            prev_ws = false;
            i += 1;
        } else {
            if (decodeUtf8At(label, i)) |r| {
                if (r.cp == 0x1E9E) {
                    try buf.appendSlice(allocator, "ss");
                } else {
                    const lower = unicodeCaseFold(r.cp);
                    var enc_buf: [4]u8 = undefined;
                    const enc_len = encodeUtf8(lower, &enc_buf);
                    try buf.appendSlice(allocator, enc_buf[0..enc_len]);
                }
                prev_ws = false;
                i += r.len;
            } else {
                try buf.append(allocator, c);
                prev_ws = false;
                i += 1;
            }
        }
    }
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') _ = buf.pop();
    return buf.toOwnedSlice(allocator);
}

/// Resolve a reference label against the ref map, returning owned copies of url/title.
const ResolvedRef = struct { url: []const u8, title: ?[]const u8 };

fn resolveRef(allocator: Allocator, rm: *const RefMap, label: []const u8) ?ResolvedRef {
    const norm = normalizeLabel(allocator, label) catch return null;
    defer allocator.free(norm);
    const dest = rm.get(norm) orelse return null;
    const url = allocator.dupe(u8, dest.url) catch return null;
    const title: ?[]const u8 = if (dest.title) |t| (allocator.dupe(u8, t) catch return null) else null;
    return .{ .url = url, .title = title };
}

/// Try to consume a link reference definition starting at `lines[start]`.
/// Builds a multi-line candidate (up to `max_continuation` lines total),
/// parses it, and inserts into `ref_map` (first definition wins).
/// Returns the number of lines consumed, or null if no valid definition.
fn tryConsumeLinkRefDef(
    allocator: Allocator,
    lines: []const []const u8,
    start: usize,
    max_continuation: usize,
    ref_map: *RefMap,
) !?usize {
    const line = lines[start];
    const tl = mem.trimLeft(u8, line, " ");
    if (tl.len == 0 or tl[0] != '[') return null;
    if (tl.len > 1 and tl[1] == '^') return null;

    var candidate = std.ArrayList(u8){};
    defer candidate.deinit(allocator);
    try candidate.appendSlice(allocator, line);
    var j = start + 1;
    var lc: usize = 1;
    while (j < lines.len and lc < max_continuation) : (j += 1) {
        if (trimLine(lines[j]).len == 0) break;
        try candidate.append(allocator, '\n');
        try candidate.appendSlice(allocator, lines[j]);
        lc += 1;
    }

    const def = parseLinkRefDef(candidate.items) orelse return null;
    const norm = try normalizeLabel(allocator, def.label);
    if (!ref_map.contains(norm)) {
        const url_dupe = try allocator.dupe(u8, def.url);
        const title_dupe: ?[]const u8 = if (def.title) |t| try allocator.dupe(u8, t) else null;
        try ref_map.put(norm, .{ .url = url_dupe, .title = title_dupe });
    } else {
        allocator.free(norm);
    }
    // Count consumed lines
    var consumed: usize = 1;
    var ci: usize = 0;
    while (ci < def.consumed and ci < candidate.items.len) : (ci += 1) {
        if (candidate.items[ci] == '\n') consumed += 1;
    }
    return consumed;
}

/// Parse a link reference definition from concatenated lines.
fn parseLinkRefDef(line: []const u8) ?struct { label: []const u8, url: []const u8, title: ?[]const u8, consumed: usize } {
    var pos: usize = 0;
    var leading_spaces: usize = 0;
    while (pos < line.len and leading_spaces < 3 and line[pos] == ' ') {
        pos += 1;
        leading_spaces += 1;
    }
    if (pos >= line.len or line[pos] != '[') return null;
    pos += 1;
    const label_start = pos;
    var label_char_count: usize = 0;
    while (pos < line.len) {
        if (line[pos] == '\\' and pos + 1 < line.len) {
            pos += 2;
            label_char_count += 2;
        } else if (line[pos] == ']') break else if (line[pos] == '[') return null else {
            if (line[pos] != '\n') label_char_count += 1;
            pos += 1;
        }
    }
    if (pos >= line.len) return null;
    if (label_char_count > 999) return null;
    const label = line[label_start..pos];
    if (label.len == 0) return null;
    var all_ws = true;
    for (label) |c| if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
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
            } else if (line[pos] == '<') return null else {
                pos += 1;
            }
        }
        if (pos >= line.len or line[pos] != '>') return null;
        url = line[url_start..pos];
        pos += 1;
    } else {
        const url_start = pos;
        var pd: i32 = 0;
        while (pos < line.len) {
            const c = line[pos];
            if (c == '\\' and pos + 1 < line.len) {
                pos += 2;
            } else if (c == '(') {
                pd += 1;
                pos += 1;
            } else if (c == ')') {
                if (pd == 0) break;
                pd -= 1;
                pos += 1;
            } else if (c == ' ' or c == '\t' or c == '\n') break else if (c <= 0x1f) return null else {
                pos += 1;
            }
        }
        if (pd != 0) return null;
        url = line[url_start..pos];
    }

    const pos_after_url = pos;
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    const had_space = pos > pos_after_url;
    const pos_before_title = pos;

    if (pos < line.len and line[pos] == '\n') {
        const saved = pos;
        pos += 1;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
        if (pos >= line.len) return .{ .label = label, .url = url, .title = null, .consumed = saved };
        if (line[pos] != '"' and line[pos] != '\'' and line[pos] != '(')
            return .{ .label = label, .url = url, .title = null, .consumed = saved };
    }

    var title: ?[]const u8 = null;
    if (pos < line.len and (line[pos] == '"' or line[pos] == '\'' or line[pos] == '(')) {
        if (!had_space and pos == pos_after_url) return null;
        const title_open = line[pos];
        const title_close: u8 = if (title_open == '(') ')' else title_open;
        pos += 1;
        const title_start = pos;
        while (pos < line.len) {
            if (line[pos] == '\\' and pos + 1 < line.len) {
                pos += 2;
            } else if (line[pos] == title_close) break else if (line[pos] == '\n') {
                if (pos + 1 < line.len and line[pos + 1] == '\n') return null;
                pos += 1;
            } else {
                pos += 1;
            }
        }
        if (pos >= line.len) return null;
        title = line[title_start..pos];
        pos += 1;
    } else if (pos < line.len and line[pos] != '\n') {
        return null;
    }

    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    if (pos < line.len and line[pos] != '\n') {
        if (title != null) {
            if (pos_before_title >= line.len or line[pos_before_title] == '\n')
                return .{ .label = label, .url = url, .title = null, .consumed = pos_before_title };
            return null;
        }
        return null;
    }

    return .{ .label = label, .url = url, .title = title, .consumed = pos };
}

// ── Inline parser ─────────────────────────────────────────────────────────────

fn isUriAutolink(s: []const u8) bool {
    // Scheme must be 2-32 characters (letters, digits, +, -, .)
    // and start with a letter
    var i: usize = 0;
    if (i >= s.len or !((s[i] >= 'a' and s[i] <= 'z') or (s[i] >= 'A' and s[i] <= 'Z'))) return false;
    i += 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '+' or c == '-' or c == '.')) break;
    }
    if (i < 2 or i > 32) return false; // scheme must be 2-32 chars
    if (i >= s.len or s[i] != ':') return false;
    // No spaces, <, or > allowed in the rest
    for (s) |c| if (c == ' ' or c == '<' or c == '>') return false;
    return true;
}

fn isEmailAutolink(s: []const u8) bool {
    // Backslash in email makes it not a valid autolink
    for (s) |c| if (c == '\\') return false;
    const at = mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at + 1 >= s.len) return false;
    return mem.indexOf(u8, s, " ") == null;
}

fn containsLink(items: []const AST.Inline) bool {
    for (items) |item| switch (item) {
        .link => return true,
        .emphasis => |e| {
            if (containsLink(e.children.items)) return true;
        },
        .strong => |s| {
            if (containsLink(s.children.items)) return true;
        },
        else => {},
    };
    return false;
}

fn findClosingBracket(input: []const u8, start: usize) ?usize {
    var pos = start;
    var depth: i32 = 0;
    while (pos < input.len) {
        const c = input[pos];
        if (c == '\\' and pos + 1 < input.len and isAsciiPunct(input[pos + 1])) {
            pos += 2;
            continue;
        }
        if (c == '`') {
            var tl: usize = 0;
            while (pos + tl < input.len and input[pos + tl] == '`') tl += 1;
            const cs = pos + tl;
            var se = cs;
            var found_close = false;
            while (se < input.len) {
                if (input[se] == '`') {
                    var cl: usize = 0;
                    while (se + cl < input.len and input[se + cl] == '`') cl += 1;
                    if (cl == tl) {
                        pos = se + cl;
                        found_close = true;
                        break;
                    }
                    se += cl;
                } else se += 1;
            }
            if (found_close) continue;
            pos += tl;
            continue;
        }
        if (c == '<') {
            if (pos + 1 < input.len) {
                if (mem.indexOfScalarPos(u8, input, pos + 1, '>')) |close| {
                    const inner = input[pos + 1 .. close];
                    if (isUriAutolink(inner) or isEmailAutolink(inner)) {
                        pos = close + 1;
                        continue;
                    }
                }
            }
            if (tryParseHtmlTag(input, pos)) |end| {
                pos = end;
                continue;
            }
            pos += 1;
            continue;
        }
        if (c == '[') {
            depth += 1;
            pos += 1;
            continue;
        }
        if (c == ']') {
            if (depth == 0) return pos;
            depth -= 1;
            pos += 1;
            continue;
        }
        pos += 1;
    }
    return null;
}

fn tryParseLink(input: []const u8, start: usize) ?struct {
    text: []const u8,
    url: []const u8,
    title: ?[]const u8,
    end: usize,
} {
    if (start >= input.len or input[start] != '[') return null;
    const be = findClosingBracket(input, start + 1) orelse return null;
    const link_text = input[start + 1 .. be];
    if (be + 1 >= input.len or input[be + 1] != '(') return null;
    var pos = be + 2;

    while (pos < input.len and (input[pos] == ' ' or input[pos] == '\t' or input[pos] == '\n' or input[pos] == '\r')) pos += 1;
    if (pos >= input.len) return null;

    var url: []const u8 = undefined;
    if (input[pos] == '<') {
        const us = pos + 1;
        pos += 1;
        while (pos < input.len) {
            if (input[pos] == '\\' and pos + 1 < input.len) {
                pos += 2;
            } else if (input[pos] == '>') break else if (input[pos] == '<' or input[pos] == '\n') return null else {
                pos += 1;
            }
        }
        if (pos >= input.len) return null;
        url = input[us..pos];
        pos += 1;
    } else if (input[pos] == ')') {
        url = "";
    } else {
        const us = pos;
        var pd: i32 = 0;
        while (pos < input.len) {
            const ch = input[pos];
            if (ch == '\\' and pos + 1 < input.len and isAsciiPunct(input[pos + 1])) {
                pos += 2;
            } else if (ch == '(') {
                pd += 1;
                pos += 1;
            } else if (ch == ')') {
                if (pd == 0) break;
                pd -= 1;
                pos += 1;
            } else if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') break else if (ch <= 0x1f) return null else {
                pos += 1;
            }
        }
        if (pd != 0) return null;
        url = input[us..pos];
    }

    while (pos < input.len and (input[pos] == ' ' or input[pos] == '\t' or input[pos] == '\n' or input[pos] == '\r')) pos += 1;
    if (pos >= input.len) return null;
    if (input[pos] == ')') return .{ .text = link_text, .url = url, .title = null, .end = pos + 1 };

    const tc: u8 = switch (input[pos]) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };
    pos += 1;
    const ts = pos;
    while (pos < input.len) {
        if (input[pos] == '\\' and pos + 1 < input.len) {
            pos += 2;
        } else if (input[pos] == tc) break else {
            pos += 1;
        }
    }
    if (pos >= input.len) return null;
    const title = input[ts..pos];
    pos += 1;
    while (pos < input.len and (input[pos] == ' ' or input[pos] == '\t' or input[pos] == '\n' or input[pos] == '\r')) pos += 1;
    if (pos >= input.len or input[pos] != ')') return null;
    return .{ .text = link_text, .url = url, .title = title, .end = pos + 1 };
}

// ── CommonMark emphasis (delimiter algorithm) ────────────────────────────────

fn isUnicodeWhitespace(input: []const u8, pos: usize) bool {
    if (pos >= input.len) return false;
    const c = input[pos];
    if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c or c == 0x0b) return true;
    const start = utf8CharStart(input, pos);
    if (decodeUtf8At(input, start)) |r| return isUnicodeCodepointWhitespace(r.cp);
    return false;
}

fn isUnicodeCodepointWhitespace(cp: u21) bool {
    return switch (cp) {
        0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn isUnicodePunct(input: []const u8, pos: usize) bool {
    if (pos >= input.len) return false;
    const start = utf8CharStart(input, pos);
    const c = input[start];
    if (c < 0x80) return isAsciiPunct(c);
    if (decodeUtf8At(input, start)) |r| return isUnicodeCodepointPunct(r.cp);
    return false;
}

fn isUnicodeCodepointPunct(cp: u32) bool {
    const UR = @import("unicode_ranges.zig");
    for (UR.ranges) |r| {
        if (cp < r[0]) return false;
        if (cp <= r[1]) return true;
    }
    return false;
}

fn isLeftFlanking(input: []const u8, rs: usize, rl: usize) bool {
    const re = rs + rl;
    if (re >= input.len) return false;
    if (isUnicodeWhitespace(input, re)) return false;
    if (!isUnicodePunct(input, re)) return true;
    return rs == 0 or isUnicodeWhitespace(input, rs - 1) or isUnicodePunct(input, rs - 1);
}

fn isRightFlanking(input: []const u8, rs: usize, rl: usize) bool {
    const re = rs + rl;
    if (rs == 0) return false;
    if (isUnicodeWhitespace(input, rs - 1)) return false;
    if (!isUnicodePunct(input, rs - 1)) return true;
    return re >= input.len or isUnicodeWhitespace(input, re) or isUnicodePunct(input, re);
}

fn canOpen(input: []const u8, marker: u8, rs: usize, rl: usize) bool {
    const lf = isLeftFlanking(input, rs, rl);
    if (marker == '*') return lf;
    return lf and (!isRightFlanking(input, rs, rl) or (rs > 0 and isUnicodePunct(input, rs - 1)));
}

fn canClose(input: []const u8, marker: u8, rs: usize, rl: usize) bool {
    const rf = isRightFlanking(input, rs, rl);
    if (marker == '*') return rf;
    return rf and (!isLeftFlanking(input, rs, rl) or (rs + rl < input.len and isUnicodePunct(input, rs + rl)));
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

/// Wrap inline nodes between opener and closer in an Emphasis or Strong node
/// (depending on `use_count`), splice the node into the inline list, and
/// fix up delimiter indices.
fn wrapDelimiters(
    allocator: Allocator,
    inlines: *std.ArrayList(AST.Inline),
    delimiters: *std.ArrayList(Delimiter),
    opener_idx: usize,
    closer_idx: usize,
    use_count: usize,
) !void {
    const opener = &delimiters.items[opener_idx];
    const closer = &delimiters.items[closer_idx];
    const open_il = opener.inline_idx;
    const close_il = closer.inline_idx;

    // Gather children between opener and closer
    var children = std.ArrayList(AST.Inline){};
    var ci = open_il + 1;
    while (ci < close_il) : (ci += 1) try children.append(allocator, inlines.items[ci]);

    const node: AST.Inline = if (use_count == 2)
        .{ .strong = .{ .children = children, .marker = closer.marker } }
    else
        .{ .emphasis = .{ .children = children, .marker = closer.marker } };

    opener.count -= use_count;
    closer.count -= use_count;

    if (opener.count > 0)
        inlines.items[open_il] = .{ .text = .{ .content = inlines.items[open_il].text.content[0..opener.count] } };
    if (closer.count > 0)
        inlines.items[close_il] = .{ .text = .{ .content = inlines.items[close_il].text.content[0..closer.count] } };

    const rm_start = if (opener.count > 0) open_il + 1 else open_il;
    const rm_end = if (closer.count > 0) close_il else close_il + 1;

    if (rm_end > rm_start) {
        const removed = rm_end - rm_start;
        inlines.items[rm_start] = node;
        if (removed > 1) {
            var si = rm_start + 1;
            while (si + removed - 1 < inlines.items.len) : (si += 1)
                inlines.items[si] = inlines.items[si + removed - 1];
            inlines.items.len -= removed - 1;
        }
        for (delimiters.items) |*d| {
            if (d.inline_idx > rm_start and d.inline_idx < rm_end) d.active = false else if (d.inline_idx >= rm_end) d.inline_idx -= removed - 1;
        }
    }

    var di = opener_idx + 1;
    while (di < closer_idx) : (di += 1) delimiters.items[di].active = false;
    if (opener.count == 0) opener.active = false;
}

fn processEmphasis(allocator: Allocator, inlines: *std.ArrayList(AST.Inline), delimiters: *std.ArrayList(Delimiter)) !void {
    var closer_idx: usize = 0;
    while (closer_idx < delimiters.items.len) {
        var closer = &delimiters.items[closer_idx];
        if (!closer.active or !closer.can_close) {
            closer_idx += 1;
            continue;
        }

        var found = false;
        var oi: usize = closer_idx;
        while (oi > 0) {
            oi -= 1;
            const opener = &delimiters.items[oi];
            if (!opener.active or !opener.can_open or opener.marker != closer.marker) continue;
            if ((opener.can_close or closer.can_open) and
                (opener.orig_count + closer.orig_count) % 3 == 0 and
                opener.orig_count % 3 != 0 and closer.orig_count % 3 != 0) continue;

            found = true;
            const uc: usize = if (closer.count >= 2 and opener.count >= 2) 2 else 1;
            try wrapDelimiters(allocator, inlines, delimiters, oi, closer_idx, uc);
            closer = &delimiters.items[closer_idx]; // refresh after splice
            if (closer.count == 0) {
                closer.active = false;
                closer_idx += 1;
            }
            break;
        }
        if (!found) {
            if (!closer.can_open) closer.active = false;
            closer_idx += 1;
        }
    }
    // Remove empty text nodes
    var w: usize = 0;
    for (inlines.items) |item| {
        const skip = switch (item) {
            .text => |t| t.content.len == 0,
            else => false,
        };
        if (!skip) {
            inlines.items[w] = item;
            w += 1;
        }
    }
    inlines.items.len = w;
}

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
            if (tryParseCodeSpan(allocator, input, pos)) |r| {
                try inlines.append(allocator, .{ .code_span = .{ .content = r.content } });
                pos = r.end;
                continue;
            }
            var tl: usize = 0;
            while (pos + tl < input.len and input[pos + tl] == '`') tl += 1;
            try inlines.append(allocator, .{ .text = .{ .content = input[pos .. pos + tl] } });
            pos += tl;
            continue;
        }

        // Raw HTML / Autolinks
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
            if (tryParseHtmlTag(input, pos)) |end| {
                try inlines.append(allocator, .{ .html_in_line = .{ .content = input[pos..end] } });
                pos = end;
                continue;
            }
        }

        // Image ![alt](url) or ![alt][ref]
        if (c == '!' and pos + 1 < input.len and input[pos + 1] == '[') {
            if (tryParseLink(input, pos + 1)) |r| {
                const alt = try flattenInlineText(allocator, r.text, ref_map);
                try inlines.append(allocator, .{ .image = .{
                    .alt_text = alt,
                    .destination = .{
                        .url = try allocator.dupe(u8, r.url),
                        .title = if (r.title) |t| try allocator.dupe(u8, t) else null,
                    },
                    .link_type = .in_line,
                } });
                pos = r.end;
                continue;
            }
            if (ref_map) |rm| {
                if (tryParseImageRefLink(allocator, input, pos, rm)) |r| {
                    try inlines.append(allocator, r.inline_node);
                    pos = r.end;
                    continue;
                }
            }
        }

        // Footnote ref / inline link / reference link
        if (c == '[') {
            if (pos + 1 < input.len and input[pos + 1] == '^') {
                if (mem.indexOfScalarPos(u8, input, pos + 2, ']')) |close| {
                    if (close > pos + 2) {
                        try inlines.append(allocator, .{ .footnote_reference = .{ .label = input[pos + 2 .. close] } });
                        pos = close + 1;
                        continue;
                    }
                }
            }
            if (tryParseLink(input, pos)) |r| {
                var nested = try parseInlineElements(allocator, r.text, ref_map);
                if (containsLink(nested.items)) {
                    for (nested.items) |*item| item.deinit(allocator);
                    nested.deinit(allocator);
                    try inlines.append(allocator, .{ .text = .{ .content = "[" } });
                    pos += 1;
                    continue;
                }
                var link = AST.Link.init(allocator, .{
                    .url = try allocator.dupe(u8, r.url),
                    .title = if (r.title) |t| try allocator.dupe(u8, t) else null,
                }, .in_line);
                defer nested.deinit(allocator);
                for (nested.items) |item| try link.children.append(allocator, item);
                try inlines.append(allocator, .{ .link = link });
                pos = r.end;
                continue;
            }
            if (ref_map) |rm| {
                if (tryParseRefLink(allocator, input, pos, rm)) |r| {
                    try inlines.append(allocator, r.inline_node);
                    pos = r.end;
                    continue;
                }
            }
        }

        // Emphasis/strong delimiter
        if (c == '*' or c == '_') {
            const rs = pos;
            var rl: usize = 0;
            while (pos + rl < input.len and input[pos + rl] == c) rl += 1;
            const opens = canOpen(input, c, rs, rl);
            const closes = canClose(input, c, rs, rl);
            try inlines.append(allocator, .{ .text = .{ .content = input[rs .. rs + rl] } });
            if (opens or closes)
                try delimiters.append(allocator, .{
                    .inline_idx = inlines.items.len - 1,
                    .input_pos = rs,
                    .count = rl,
                    .orig_count = rl,
                    .marker = c,
                    .can_open = opens,
                    .can_close = closes,
                    .active = true,
                });
            pos += rl;
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
            try inlines.append(allocator, if (is_hard) .{ .hard_break = .{} } else .{ .soft_break = .{} });
            pos += 1;
        } else {
            try inlines.append(allocator, .{ .text = .{ .content = input[pos .. pos + 1] } });
            pos += 1;
        }
    }

    try processEmphasis(allocator, &inlines, &delimiters);
    return inlines;
}

/// Try to parse a code span starting at `pos` (which points to the first backtick).
fn tryParseCodeSpan(allocator: Allocator, input: []const u8, pos: usize) ?struct { content: []const u8, end: usize } {
    var tl: usize = 0;
    while (pos + tl < input.len and input[pos + tl] == '`') tl += 1;
    const cs = pos + tl;
    var se = cs;
    while (se < input.len) {
        if (input[se] == '`') {
            var cl: usize = 0;
            while (se + cl < input.len and input[se + cl] == '`') cl += 1;
            if (cl == tl) {
                const raw = input[cs..se];
                var code_buf = std.ArrayList(u8){};
                for (raw) |ch| code_buf.append(allocator, if (ch == '\n') ' ' else ch) catch return null;
                var final: []const u8 = code_buf.items;
                if (final.len >= 2 and final[0] == ' ' and final[final.len - 1] == ' ') {
                    var all_spaces = true;
                    for (final) |ch| if (ch != ' ') {
                        all_spaces = false;
                        break;
                    };
                    if (!all_spaces) final = final[1 .. final.len - 1];
                }
                const duped = allocator.dupe(u8, final) catch return null;
                code_buf.deinit(allocator);
                return .{ .content = duped, .end = se + cl };
            }
            se += cl;
        } else se += 1;
    }
    return null;
}

fn flattenInlineText(allocator: Allocator, input: []const u8, ref_map: ?*const RefMap) Allocator.Error![]const u8 {
    var inlines = try parseInlineElements(allocator, input, ref_map);
    defer {
        for (inlines.items) |*item| item.deinit(allocator);
        inlines.deinit(allocator);
    }
    var buf = std.ArrayList(u8){};
    for (inlines.items) |item| try flattenInline(allocator, &buf, item);
    return buf.toOwnedSlice(allocator);
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
        .hard_break, .autolink, .footnote_reference, .html_in_line => {},
    }
}

fn tryParseHtmlTag(input: []const u8, pos: usize) ?usize {
    if (pos >= input.len or input[pos] != '<' or pos + 1 >= input.len) return null;
    const next = input[pos + 1];
    // Opening tag
    if ((next >= 'a' and next <= 'z') or (next >= 'A' and next <= 'Z')) {
        var i = pos + 2;
        while (i < input.len and ((input[i] >= 'a' and input[i] <= 'z') or (input[i] >= 'A' and input[i] <= 'Z') or
            (input[i] >= '0' and input[i] <= '9') or input[i] == '-')) i += 1;
        while (i < input.len) {
            const before_ws = i;
            while (i < input.len and (input[i] == ' ' or input[i] == '\t' or input[i] == '\n' or input[i] == '\r')) i += 1;
            if (i >= input.len) return null;
            if (input[i] == '>') return i + 1;
            if (input[i] == '/') {
                i += 1;
                return if (i < input.len and input[i] == '>') i + 1 else null;
            }
            // Must have had whitespace before attribute name
            if (i == before_ws) return null;
            if (!((input[i] >= 'a' and input[i] <= 'z') or (input[i] >= 'A' and input[i] <= 'Z') or input[i] == '_' or input[i] == ':')) return null;
            i += 1;
            while (i < input.len and ((input[i] >= 'a' and input[i] <= 'z') or (input[i] >= 'A' and input[i] <= 'Z') or
                (input[i] >= '0' and input[i] <= '9') or input[i] == '_' or input[i] == '.' or input[i] == ':' or input[i] == '-')) i += 1;
            var j = i;
            while (j < input.len and (input[j] == ' ' or input[j] == '\t' or input[j] == '\n' or input[j] == '\r')) j += 1;
            if (j < input.len and input[j] == '=') {
                j += 1;
                while (j < input.len and (input[j] == ' ' or input[j] == '\t' or input[j] == '\n' or input[j] == '\r')) j += 1;
                if (j >= input.len) return null;
                if (input[j] == '\'' or input[j] == '"') {
                    const q = input[j];
                    j += 1;
                    while (j < input.len and input[j] != q) j += 1;
                    if (j >= input.len) return null;
                    j += 1;
                } else {
                    const vs = j;
                    while (j < input.len and input[j] != ' ' and input[j] != '\t' and input[j] != '\n' and input[j] != '\r' and
                        input[j] != '"' and input[j] != '\'' and input[j] != '=' and input[j] != '<' and input[j] != '>' and input[j] != '`') j += 1;
                    if (j == vs) return null;
                }
                i = j;
            }
            // For boolean attributes (no '='), don't advance i past the
            // attribute name — leave whitespace for the next iteration's
            // "must have whitespace before attribute" check.
        }
        return null;
    }
    // Closing tag
    if (next == '/') {
        var i = pos + 2;
        if (i >= input.len or !((input[i] >= 'a' and input[i] <= 'z') or (input[i] >= 'A' and input[i] <= 'Z'))) return null;
        while (i < input.len and ((input[i] >= 'a' and input[i] <= 'z') or (input[i] >= 'A' and input[i] <= 'Z') or
            (input[i] >= '0' and input[i] <= '9') or input[i] == '-')) i += 1;
        while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
        return if (i < input.len and input[i] == '>') i + 1 else null;
    }
    // Comment: <!-- text --> where text doesn't start with > or ->
    // and doesn't end with - and doesn't contain --
    // Special cases: <!--> and <!---> are valid (empty) comments per CommonMark 0.31.2
    if (pos + 3 < input.len and input[pos + 1] == '!' and input[pos + 2] == '-' and input[pos + 3] == '-') {
        const after = pos + 4;
        // <!--> is a valid comment
        if (after < input.len and input[after] == '>') return after + 1;
        // <!---> is a valid comment
        if (after + 1 < input.len and input[after] == '-' and input[after + 1] == '>') return after + 2;
        var i = after;
        while (i + 2 < input.len) : (i += 1) if (input[i] == '-' and input[i + 1] == '-' and input[i + 2] == '>') return i + 3;
        return null;
    }
    // PI
    if (next == '?') {
        var i = pos + 2;
        while (i + 1 < input.len) : (i += 1) if (input[i] == '?' and input[i + 1] == '>') return i + 2;
        return null;
    }
    // CDATA
    if (pos + 8 < input.len and mem.startsWith(u8, input[pos..], "<![CDATA[")) {
        var i = pos + 9;
        while (i + 2 < input.len) : (i += 1) if (input[i] == ']' and input[i + 1] == ']' and input[i + 2] == '>') return i + 3;
        return null;
    }
    // Declaration
    if (next == '!' and pos + 2 < input.len and ((input[pos + 2] >= 'a' and input[pos + 2] <= 'z') or (input[pos + 2] >= 'A' and input[pos + 2] <= 'Z'))) {
        var i = pos + 3;
        while (i < input.len and input[i] != '>') i += 1;
        return if (i < input.len) i + 1 else null;
    }
    return null;
}

const InlineParseResult = struct { inline_node: AST.Inline, end: usize };

fn tryParseImageRefLink(allocator: Allocator, input: []const u8, start: usize, rm: *const RefMap) ?InlineParseResult {
    if (start >= input.len or input[start] != '!' or start + 1 >= input.len or input[start + 1] != '[') return null;
    const be = findClosingBracket(input, start + 2) orelse return null;
    const raw_alt = input[start + 2 .. be];

    // Full reference: ![alt][label]
    if (be + 1 < input.len and input[be + 1] == '[') {
        // Collapsed: ![alt][]
        if (be + 2 < input.len and input[be + 2] == ']') {
            if (resolveRef(allocator, rm, raw_alt)) |ref| {
                const flat = flattenInlineText(allocator, raw_alt, rm) catch return null;
                return .{ .inline_node = .{ .image = .{ .alt_text = flat, .destination = .{ .url = ref.url, .title = ref.title }, .link_type = .collapsed } }, .end = be + 3 };
            }
        } else {
            var le: usize = be + 2;
            while (le < input.len and input[le] != ']') le += 1;
            if (le < input.len) {
                if (resolveRef(allocator, rm, input[be + 2 .. le])) |ref| {
                    const flat = flattenInlineText(allocator, raw_alt, rm) catch return null;
                    return .{ .inline_node = .{ .image = .{ .alt_text = flat, .destination = .{ .url = ref.url, .title = ref.title }, .link_type = .reference } }, .end = le + 1 };
                }
            }
        }
    }
    // Shortcut: ![alt]
    if (resolveRef(allocator, rm, raw_alt)) |ref| {
        const flat = flattenInlineText(allocator, raw_alt, rm) catch return null;
        return .{ .inline_node = .{ .image = .{ .alt_text = flat, .destination = .{ .url = ref.url, .title = ref.title }, .link_type = .shortcut } }, .end = be + 1 };
    }
    return null;
}

fn tryParseRefLink(allocator: Allocator, input: []const u8, start: usize, rm: *const RefMap) ?InlineParseResult {
    if (start >= input.len or input[start] != '[') return null;
    const be = findClosingBracket(input, start + 1) orelse return null;
    const link_text = input[start + 1 .. be];
    var tried_full = false;

    if (be + 1 < input.len and input[be + 1] == '[') {
        tried_full = true;
        // Collapsed: [text][]
        if (be + 2 < input.len and input[be + 2] == ']') {
            if (resolveRef(allocator, rm, link_text)) |ref|
                return buildRefLink(allocator, link_text, ref, .collapsed, be + 3, rm);
        } else {
            // Full: [text][label]
            var le: usize = be + 2;
            while (le < input.len and input[le] != ']') le += 1;
            if (le < input.len) {
                if (resolveRef(allocator, rm, input[be + 2 .. le])) |ref|
                    return buildRefLink(allocator, link_text, ref, .reference, le + 1, rm);
            }
        }
    }
    // Shortcut: [text]
    if (!tried_full) {
        if (resolveRef(allocator, rm, link_text)) |ref|
            return buildRefLink(allocator, link_text, ref, .shortcut, be + 1, rm);
    }
    return null;
}

fn buildRefLink(
    allocator: Allocator,
    text: []const u8,
    ref: ResolvedRef,
    link_type: AST.LinkType,
    end: usize,
    rm: ?*const RefMap,
) ?InlineParseResult {
    var link = AST.Link.init(allocator, .{ .url = ref.url, .title = ref.title }, link_type);
    var nested = parseInlineElements(allocator, text, rm) catch return null;
    if (containsLink(nested.items)) {
        // Can't nest links — free the ref-owned url/title and nested inlines.
        for (nested.items) |*item| item.deinit(allocator);
        nested.deinit(allocator);
        allocator.free(ref.url);
        if (ref.title) |t| allocator.free(t);
        return null;
    }
    for (nested.items) |item| link.children.append(allocator, item) catch return null;
    nested.deinit(allocator);
    return .{ .inline_node = .{ .link = link }, .end = end };
}

// ── Block parser ──────────────────────────────────────────────────────────────

const Self = @This();

/// When true, setext heading underlines inside paragraphs are disabled.
/// Used when re-parsing blockquote inner content that includes lazy
/// continuation lines which must not form setext headings.
has_lazy_setext: bool = false,

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

/// Split input into lines, normalising CRLF/CR to LF.
fn splitLines(allocator: Allocator, input: []const u8) !std.ArrayList([]const u8) {
    var list = std.ArrayList([]const u8){};
    var it = mem.splitScalar(u8, input, '\n');
    while (it.next()) |raw| {
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        try list.append(allocator, line);
    }
    return list;
}

/// Skip optional `---`/`+++`/`%%%` frontmatter; return first content line index.
/// Only treats it as frontmatter if there's at least one line with `:` (key-value).
fn skipFrontmatter(lines: []const []const u8) usize {
    if (lines.len == 0) return 0;
    const fl = trimLine(lines[0]);
    if (!mem.eql(u8, fl, "---") and !mem.eql(u8, fl, "+++") and !mem.eql(u8, fl, "%%%")) return 0;
    var fi: usize = 1;
    var has_kv = false;
    while (fi < lines.len) {
        const tl = trimLine(lines[fi]);
        fi += 1;
        if (mem.eql(u8, tl, "---") or mem.eql(u8, tl, "+++") or mem.eql(u8, tl, "%%%")) {
            // Only treat as frontmatter if we found key-value content
            return if (has_kv) fi else 0;
        }
        if (mem.indexOf(u8, tl, ":") != null) has_kv = true;
    }
    return 0;
}

fn collectLinkRefDefs(allocator: Allocator, input: []const u8, ref_map: *RefMap) !void {
    var lines_list = try splitLines(allocator, input);
    defer lines_list.deinit(allocator);
    const lines = lines_list.items;
    var i = skipFrontmatter(lines);

    var in_paragraph = false;
    var in_fenced = false;
    var fence_info: ?parsers.FenceInfo = null;

    while (i < lines.len) {
        const line = lines[i];
        const t = trimLine(line);

        if (in_fenced) {
            if (fence_info) |fi| if (parsers.isFenceEnd(line, fi)) {
                in_fenced = false;
                fence_info = null;
            };
            i += 1;
            continue;
        }
        if (parsers.tryFenceStart(line)) |fi| {
            in_fenced = true;
            fence_info = fi;
            in_paragraph = false;
            i += 1;
            continue;
        }
        if (t.len == 0) {
            in_paragraph = false;
            i += 1;
            continue;
        }
        if (t[0] == '#' or isThematicBreak(line)) {
            in_paragraph = false;
            i += 1;
            continue;
        }

        // Blockquote: strip prefixes and scan inner content for ref defs
        if (t[0] == '>') {
            in_paragraph = false;
            var bq = std.ArrayList(u8){};
            while (i < lines.len) {
                const bt = trimLine(lines[i]);
                if (bt.len == 0 or bt[0] != '>') break;
                const stripped = if (bt.len > 1 and bt[1] == ' ') bt[2..] else bt[1..];
                if (bq.items.len > 0) try bq.append(allocator, '\n');
                try bq.appendSlice(allocator, stripped);
                i += 1;
            }
            if (bq.items.len > 0) {
                var inner = try splitLines(allocator, bq.items);
                defer inner.deinit(allocator);
                var bi: usize = 0;
                while (bi < inner.items.len) {
                    if (try tryConsumeLinkRefDef(allocator, inner.items, bi, 5, ref_map)) |consumed| {
                        bi += consumed;
                    } else bi += 1;
                }
            }
            bq.deinit(allocator);
            continue;
        }

        if (parsers.tryIndentedCode(line) != null and !in_paragraph) {
            i += 1;
            continue;
        }
        if (in_paragraph and (isSetextEqLine(t) or isSetextDashLine(t))) {
            in_paragraph = false;
            i += 1;
            continue;
        }
        if (bulletListContentColumn(line) != null or orderedListContentColumn(line) != null) {
            in_paragraph = false;
            i += 1;
            continue;
        }

        if (!in_paragraph) {
            if (try tryConsumeLinkRefDef(allocator, lines, i, 5, ref_map)) |consumed| {
                i += consumed;
                continue;
            }
        }
        in_paragraph = true;
        i += 1;
    }
}

// ── List parsing ─────────────────────────────────────────────────────────────

const ListParseConfig = struct {
    list_type: AST.ListType,
    marker: u8,
    delimiter: u8,
    start_num: u32,
};

const ItemContinuation = struct {
    next_line: usize,
    saw_blank: bool,
    /// True when a blank line was seen before a line that starts a sub-list
    /// at the item's own content level (indent 0 relative to item content).
    saw_blank_before_sublist: bool,
    pending_blanks: usize,
};

/// Collect continuation lines for a single list item, starting from `start`
/// (the line AFTER the marker line). Appends to `item_buf`.
fn collectItemContinuation(
    allocator: Allocator,
    item_buf: *std.ArrayList(u8),
    lines: []const []const u8,
    start: usize,
    content_col: usize,
    config: ListParseConfig,
    is_blank_item: bool,
) !ItemContinuation {
    var i = start;
    var saw_blank = false;
    var saw_blank_before_sublist = false;
    var consecutive_blanks: usize = 0;
    var pending_blanks: usize = 0;

    while (i < lines.len) {
        const line = lines[i];
        if (isBlankLine(line)) {
            consecutive_blanks += 1;
            pending_blanks += 1;
            if (is_blank_item and consecutive_blanks >= 1 and trimLine(item_buf.items).len == 0) break;
            i += 1;
            continue;
        }
        consecutive_blanks = 0;

        // Check for sibling list item
        if (isSiblingItem(line, content_col, config)) break;
        // Check for different-marker list
        if (isDifferentList(line, content_col, config)) break;

        const leading = countLeadingSpaces(line);
        if (leading >= content_col) {
            if (pending_blanks > 0) {
                saw_blank = true;
                // Check if the stripped line starts a sub-list at indent 0
                // relative to the item content.
                const stripped = stripIndent(line, content_col);
                if (bulletListContentColumn(stripped.rest) != null or orderedListContentColumn(stripped.rest) != null) {
                    saw_blank_before_sublist = true;
                }
                var b: usize = 0;
                while (b < pending_blanks) : (b += 1) try item_buf.append(allocator, '\n');
                pending_blanks = 0;
            }
            try item_buf.append(allocator, '\n');
            try appendStripped(allocator, item_buf, stripIndent(line, content_col));
            i += 1;
        } else {
            if (pending_blanks > 0) break;
            const lt = trimLine(line);
            if (lt.len == 0) break;
            if (bulletListContentColumn(line) != null or orderedListContentColumn(line) != null) break;
            if (lt[0] == '#' or lt[0] == '>' or isThematicBreak(line)) break;
            if (parsers.tryFenceStart(line) != null) break;
            // Lazy continuation
            try item_buf.append(allocator, '\n');
            // If the trimmed line looks like a list marker, add 4 spaces of
            // indent so the inner parser treats it as paragraph continuation
            // rather than a new list item (per CommonMark: lines indented 4+
            // spaces cannot start list items).
            if (bulletListContentColumn(lt) != null or orderedListContentColumn(lt) != null) {
                try item_buf.appendSlice(allocator, "    ");
            }
            try item_buf.appendSlice(allocator, lt);
            i += 1;
        }
    }
    return .{ .next_line = i, .saw_blank = saw_blank, .saw_blank_before_sublist = saw_blank_before_sublist, .pending_blanks = pending_blanks };
}

fn isSiblingItem(line: []const u8, content_col: usize, config: ListParseConfig) bool {
    if (config.list_type == .unordered) {
        if (bulletListContentColumn(line)) |info|
            return info.marker == config.marker and countLeadingSpaces(line) < content_col;
    } else {
        if (orderedListContentColumn(line)) |info|
            return info.delimiter == config.delimiter and countLeadingSpaces(line) < content_col;
    }
    return false;
}

fn isDifferentList(line: []const u8, content_col: usize, config: ListParseConfig) bool {
    if (config.list_type == .unordered) {
        if (bulletListContentColumn(line)) |info|
            return info.marker != config.marker and countLeadingSpaces(line) < content_col;
    }
    return false;
}

/// Determine whether an item's parsed blocks indicate loose content.
fn hasLooseContent(children: []const AST.Block, saw_blank: bool, saw_blank_before_sublist: bool) bool {
    if (!saw_blank) return false;
    if (children.len == 1) {
        if (children[0] == .code_block or children[0] == .fenced_code_block) return false;
    }
    var paras: usize = 0;
    var lists: usize = 0;
    var other = false;
    for (children) |child| switch (child) {
        .paragraph => paras += 1,
        .list => lists += 1,
        else => other = true,
    };
    if (paras > 1) return true;
    if (paras >= 1 and other) return true;
    // A single paragraph with no other content (except possibly lists) and a blank line:
    if (paras == 1 and lists == 0 and !other) return true;
    // Paragraph + sub-list: only loose if the blank line was between the
    // paragraph and the sub-list at this level, not inside the sub-list.
    if (paras >= 1 and lists >= 1 and saw_blank_before_sublist) return true;
    if (children.len == 0) return true;
    return false;
}

const StripResult = struct {
    rest: []const u8,
    virtual_spaces: usize,
    /// The effective column at which `rest` begins (i.e. the column reached
    /// after stripping, which is the tab-stop boundary when a tab overshot).
    effective_col: usize,
};

/// Append the content of a StripResult to an ArrayList, prepending virtual spaces.
fn appendStripped(allocator: Allocator, buf: *std.ArrayList(u8), sr: StripResult) !void {
    if (sr.virtual_spaces == 0) {
        // No column shift; tabs retain their natural positions.
        try buf.appendSlice(allocator, sr.rest);
        return;
    }
    // Emit virtual spaces (from a tab overshoot during stripping)
    var s: usize = 0;
    while (s < sr.virtual_spaces) : (s += 1) {
        try buf.append(allocator, ' ');
    }
    // Expand any leading tabs in sr.rest using the effective column
    // position so their widths match the original document layout.
    var col: usize = sr.effective_col;
    var pos: usize = 0;
    while (pos < sr.rest.len and sr.rest[pos] == '\t') {
        const tab_width = 4 - (col % 4);
        var tw: usize = 0;
        while (tw < tab_width) : (tw += 1) try buf.append(allocator, ' ');
        col += tab_width;
        pos += 1;
    }
    try buf.appendSlice(allocator, sr.rest[pos..]);
}

fn extractFirstLineContent(line: []const u8, content_col: usize) StripResult {
    var pos: usize = 0;
    var col: usize = 0;
    while (pos < line.len and col < content_col) {
        if (line[pos] == '\t') {
            const tab_width = 4 - (col % 4);
            if (col + tab_width > content_col) {
                // Tab overshoots: compute virtual spaces
                const overshoot = (col + tab_width) - content_col;
                return .{ .rest = line[pos + 1 ..], .virtual_spaces = overshoot, .effective_col = col + tab_width };
            }
            col += tab_width;
        } else {
            col += 1;
        }
        pos += 1;
    }
    return .{ .rest = if (pos >= line.len) "" else line[pos..], .virtual_spaces = 0, .effective_col = col };
}

fn stripIndent(line: []const u8, n: usize) StripResult {
    var pos: usize = 0;
    var col: usize = 0;
    while (pos < line.len and col < n) {
        if (line[pos] == '\t') {
            const tab_width = 4 - (col % 4);
            if (col + tab_width > n) {
                const overshoot = (col + tab_width) - n;
                return .{ .rest = line[pos + 1 ..], .virtual_spaces = overshoot, .effective_col = col + tab_width };
            }
            col += tab_width;
        } else if (line[pos] == ' ') {
            col += 1;
        } else break;
        pos += 1;
    }
    return .{ .rest = line[pos..], .virtual_spaces = 0, .effective_col = col };
}

fn parseList(
    allocator: Allocator,
    lines: []const []const u8,
    start: usize,
    ref_map: *const RefMap,
    config: ListParseConfig,
) anyerror!struct { list: AST.List, next_line: usize } {
    var list = AST.List.init(allocator, config.list_type);
    if (config.list_type == .ordered) list.start = config.start_num;

    var i = start;
    var had_blank_between = false;
    var any_item_loose = false;

    while (i < lines.len) {
        // A thematic break takes priority over a list item.
        // e.g. "* * *" is a thematic break, not a list item with content "* *".
        if (isThematicBreak(lines[i])) break;

        var content_col: usize = undefined;
        var first_strip: StripResult = undefined;
        var is_blank_item: bool = undefined;

        if (config.list_type == .unordered) {
            const info = bulletListContentColumn(lines[i]) orelse break;
            if (info.marker != config.marker) break;
            content_col = info.col;
            first_strip = extractFirstLineContent(lines[i], content_col);
            is_blank_item = trimLine(first_strip.rest).len == 0 and first_strip.virtual_spaces == 0;
        } else {
            const info = orderedListContentColumn(lines[i]) orelse break;
            if (info.delimiter != config.delimiter) break;
            content_col = info.col;
            first_strip = extractFirstLineContent(lines[i], content_col);
            is_blank_item = trimLine(first_strip.rest).len == 0 and first_strip.virtual_spaces == 0;
        }

        var item_buf = std.ArrayList(u8){};
        try appendStripped(allocator, &item_buf, first_strip);
        i += 1;

        const cont = try collectItemContinuation(allocator, &item_buf, lines, i, content_col, config, is_blank_item);
        i = cont.next_line;

        var item = AST.ListItem.init(allocator);
        const content = try item_buf.toOwnedSlice(allocator);
        defer allocator.free(content);
        if (trimLine(content).len > 0) {
            var inner = init();
            var inner_doc = try inner.parseMarkdownWithRefs(allocator, content, ref_map);
            for (inner_doc.children.items) |block| try item.children.append(allocator, block);
            // Free the ArrayList backing memory without deiniting moved children.
            inner_doc.children.deinit(allocator);
            inner_doc.children = std.ArrayList(AST.Block){};
        }

        if (hasLooseContent(item.children.items, cont.saw_blank, cont.saw_blank_before_sublist)) any_item_loose = true;
        try list.items.append(allocator, item);

        // Skip inter-item blank lines
        var blanks: usize = 0;
        while (i < lines.len and isBlankLine(lines[i])) {
            blanks += 1;
            i += 1;
        }
        const total_blanks = blanks + @as(usize, if (cont.pending_blanks > 0) 1 else 0);
        if (total_blanks > 0 and i < lines.len) {
            var is_next = false;
            if (config.list_type == .unordered) {
                if (bulletListContentColumn(lines[i])) |info| is_next = info.marker == config.marker;
            } else {
                if (orderedListContentColumn(lines[i])) |info| is_next = info.delimiter == config.delimiter;
            }
            if (!is_next) break;
            had_blank_between = true;
        }
    }

    list.tight = !had_blank_between and !any_item_loose;
    return .{ .list = list, .next_line = i };
}

// ── HTML block detection (CommonMark §4.6) ──────────────────────────────────

const HtmlBlockType = enum { type1, type2, type3, type4, type5, type6, type7 };

/// CommonMark HTML block type 1 tags (pre, script, style, textarea)
const html_block_type1_tags = [_][]const u8{
    "pre", "script", "style", "textarea",
};

/// Comptime set for O(1) type-6 tag lookups, replacing linear scans.
const html_block_type6_set = std.StaticStringMap(void).initComptime(.{
    .{ "address", {} },  .{ "article", {} },    .{ "aside", {} },    .{ "base", {} },
    .{ "basefont", {} }, .{ "blockquote", {} }, .{ "body", {} },     .{ "caption", {} },
    .{ "center", {} },   .{ "col", {} },        .{ "colgroup", {} }, .{ "dd", {} },
    .{ "details", {} },  .{ "dialog", {} },     .{ "dir", {} },      .{ "div", {} },
    .{ "dl", {} },       .{ "dt", {} },         .{ "fieldset", {} }, .{ "figcaption", {} },
    .{ "figure", {} },   .{ "footer", {} },     .{ "form", {} },     .{ "frame", {} },
    .{ "frameset", {} }, .{ "h1", {} },         .{ "h2", {} },       .{ "h3", {} },
    .{ "h4", {} },       .{ "h5", {} },         .{ "h6", {} },       .{ "head", {} },
    .{ "header", {} },   .{ "hr", {} },         .{ "html", {} },     .{ "iframe", {} },
    .{ "legend", {} },   .{ "li", {} },         .{ "link", {} },     .{ "main", {} },
    .{ "menu", {} },     .{ "menuitem", {} },   .{ "nav", {} },      .{ "noframes", {} },
    .{ "ol", {} },       .{ "optgroup", {} },   .{ "option", {} },   .{ "p", {} },
    .{ "param", {} },    .{ "search", {} },     .{ "section", {} },  .{ "summary", {} },
    .{ "table", {} },    .{ "tbody", {} },      .{ "td", {} },       .{ "tfoot", {} },
    .{ "th", {} },       .{ "thead", {} },      .{ "title", {} },    .{ "tr", {} },
    .{ "track", {} },    .{ "ul", {} },
});

fn startsWithTagCaseInsensitive(line: []const u8, tag: []const u8) bool {
    if (line.len < tag.len) return false;
    for (0..tag.len) |j| {
        const c = line[j];
        const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if (lower != tag[j]) return false;
    }
    // After the tag name, must have space, tab, >, />, or end of line
    if (line.len == tag.len) return true;
    const after = line[tag.len];
    return after == ' ' or after == '\t' or after == '>' or after == '/' or after == '\n' or after == '\r';
}

/// Extract an ASCII tag name from the start of a slice.
/// Returns the tag name (letters/digits only) or null if the slice
/// does not start with a valid tag name character.
fn extractTagName(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    if (!((s[0] >= 'a' and s[0] <= 'z') or (s[0] >= 'A' and s[0] <= 'Z'))) return null;
    var end: usize = 1;
    while (end < s.len and
        ((s[end] >= 'a' and s[end] <= 'z') or
            (s[end] >= 'A' and s[end] <= 'Z') or
            (s[end] >= '0' and s[end] <= '9')))
    {
        end += 1;
    }
    // After the tag name, must be whitespace, >, />, or end of line
    if (end < s.len) {
        const after = s[end];
        if (after != ' ' and after != '\t' and after != '>' and
            after != '/' and after != '\n' and after != '\r') return null;
    }
    return s[0..end];
}

fn isHtmlBlockStart(t: []const u8) bool {
    if (t.len == 0 or t[0] != '<') return false;
    const rest = t[1..];

    // Type 2: comment <!--
    if (rest.len >= 3 and rest[0] == '!' and rest[1] == '-' and rest[2] == '-') return true;

    // Type 3: processing instruction <?
    if (rest.len >= 1 and rest[0] == '?') return true;

    // Type 4: declaration <!LETTER
    if (rest.len >= 2 and rest[0] == '!' and ((rest[1] >= 'A' and rest[1] <= 'Z') or (rest[1] >= 'a' and rest[1] <= 'z'))) return true;

    // Type 5: CDATA <![CDATA[
    if (rest.len >= 8 and mem.startsWith(u8, rest, "![CDATA[")) return true;

    // Check for opening or closing tag
    var tag_start: usize = 0;
    const is_closing = rest.len > 0 and rest[0] == '/';
    if (is_closing) tag_start = 1;

    if (tag_start >= rest.len) return false;
    if (!((rest[tag_start] >= 'a' and rest[tag_start] <= 'z') or (rest[tag_start] >= 'A' and rest[tag_start] <= 'Z'))) return false;

    // Type 1: pre, script, style, textarea (opening tags ONLY per spec)
    if (!is_closing) {
        for (html_block_type1_tags) |tag| {
            if (startsWithTagCaseInsensitive(rest[tag_start..], tag)) return true;
        }
    }

    // Type 6: other block-level tags — use comptime set for O(1) lookup
    if (extractTagName(rest[tag_start..])) |tag_name| {
        var lower_buf: [32]u8 = undefined;
        if (tag_name.len <= lower_buf.len) {
            for (tag_name, 0..) |ch, idx| {
                lower_buf[idx] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
            }
            if (html_block_type6_set.has(lower_buf[0..tag_name.len])) return true;
        }
    }

    // Type 7: a complete open or closing tag followed only by optional whitespace
    // (cannot interrupt a paragraph — handled by caller)
    if (tryParseHtmlTag(t, 0)) |end| {
        const after = mem.trimRight(u8, t[end..], " \t\r");
        if (after.len == 0) return true;
    }

    return false;
}

fn htmlBlockEndCondition(t: []const u8) HtmlBlockType {
    if (t.len < 2 or t[0] != '<') return .type7;
    const rest = t[1..];
    // Type 1: pre, script, style, textarea (opening tags ONLY per spec)
    var tag_start: usize = 0;
    const is_closing = rest.len > 0 and rest[0] == '/';
    if (is_closing) tag_start = 1;
    if (!is_closing) {
        for (html_block_type1_tags) |tag| {
            if (startsWithTagCaseInsensitive(rest[tag_start..], tag)) return .type1;
        }
    }
    // Type 2: comment <!--
    if (rest.len >= 3 and rest[0] == '!' and rest[1] == '-' and rest[2] == '-') return .type2;
    // Type 3: processing instruction <?
    if (rest.len >= 1 and rest[0] == '?') return .type3;
    // Type 4: declaration <!LETTER
    if (rest.len >= 2 and rest[0] == '!' and ((rest[1] >= 'A' and rest[1] <= 'Z') or (rest[1] >= 'a' and rest[1] <= 'z'))) return .type4;
    // Type 5: CDATA <![CDATA[
    if (rest.len >= 8 and mem.startsWith(u8, rest, "![CDATA[")) return .type5;
    // Type 6: block-level tags
    if (extractTagName(rest[tag_start..])) |tag_name| {
        var lower_buf: [32]u8 = undefined;
        if (tag_name.len <= lower_buf.len) {
            for (tag_name, 0..) |ch, idx| {
                lower_buf[idx] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
            }
            if (html_block_type6_set.has(lower_buf[0..tag_name.len])) return .type6;
        }
    }
    // Type 7: complete open/close tag
    return .type7;
}

fn htmlBlockTypeEndFound(line: []const u8, block_type: HtmlBlockType) bool {
    return switch (block_type) {
        .type1 => {
            // Type 1: ends at line containing closing </pre>, </script>, </style>, or </textarea>
            for (html_block_type1_tags) |tag| {
                var search_buf: [32]u8 = undefined;
                search_buf[0] = '<';
                search_buf[1] = '/';
                @memcpy(search_buf[2 .. 2 + tag.len], tag);
                search_buf[2 + tag.len] = '>';
                // Case-insensitive search
                var pos: usize = 0;
                while (pos + 3 + tag.len <= line.len) : (pos += 1) {
                    if (line[pos] == '<' and line[pos + 1] == '/') {
                        var match = true;
                        for (0..tag.len) |j| {
                            const c = line[pos + 2 + j];
                            const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
                            if (lower != tag[j]) {
                                match = false;
                                break;
                            }
                        }
                        if (match and line[pos + 2 + tag.len] == '>') return true;
                    }
                }
            }
            return false;
        },
        .type2 => mem.indexOf(u8, line, "-->") != null,
        .type3 => mem.indexOf(u8, line, "?>") != null,
        .type4 => mem.indexOf(u8, line, ">") != null,
        .type5 => mem.indexOf(u8, line, "]]>") != null,
        else => false, // types 6/7 end at blank line, not checked here
    };
}

fn parseMarkdownWithRefs(self: Self, allocator: Allocator, input: []const u8, ref_map: *const RefMap) !AST.Document {
    var doc = AST.Document.init(allocator);
    var lines_list = try splitLines(allocator, input);
    defer lines_list.deinit(allocator);
    const lines = lines_list.items;
    var i = skipFrontmatter(lines);

    while (i < lines.len) {
        const raw = lines[i];
        const t = trimLine(raw);
        if (t.len == 0) {
            i += 1;
            continue;
        }

        // Link reference definition (already collected; skip)
        if (isLinkRefDefStart(raw)) {
            // Re-parse to determine how many lines to skip
            if (try tryConsumeLinkRefDef(allocator, lines, i, 5, @constCast(ref_map))) |consumed| {
                i += consumed;
                continue;
            }
        }

        // ATX heading
        if (parsers.tryAtxHeading(allocator, raw)) |h| {
            var heading = AST.Heading.init(allocator, h.level);
            const owned_content = try allocator.dupe(u8, h.content);
            heading.inline_source = owned_content;
            try appendInlines(allocator, &heading.children, owned_content, ref_map);
            try doc.children.append(allocator, .{ .heading = heading });
            i += 1;
            continue;
        }

        // Thematic break
        if (isThematicBreak(raw)) {
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
            try doc.children.append(allocator, .{ .code_block = .{ .content = try buf.toOwnedSlice(allocator) } });
            continue;
        }

        // Fenced code block
        if (parsers.tryFenceStart(raw)) |fence| {
            i += 1;
            var buf = std.ArrayList(u8){};
            var first_content_line = true;
            while (i < lines.len) {
                if (parsers.isFenceEnd(lines[i], fence)) {
                    i += 1;
                    break;
                }
                if (!first_content_line) try buf.append(allocator, '\n');
                first_content_line = false;
                // Strip up to `fence.indent` spaces from the start of each content line
                const strip = stripIndent(lines[i], fence.indent);
                try appendStripped(allocator, &buf, strip);
                i += 1;
            }
            // Process info string: apply backslash escapes
            const lang: ?[]const u8 = if (fence.info.len > 0) fence.info else null;
            try doc.children.append(allocator, .{ .fenced_code_block = AST.FencedCodeBlock.init(try buf.toOwnedSlice(allocator), lang, fence.char, fence.len) });
            continue;
        }

        // Blockquote
        if (parsers.tryBlockquoteLine(allocator, raw)) |_| {
            var bq_buf = std.ArrayList(u8){};
            var has_lazy_setext_line = false;
            var last_was_blank_bq = false; // track if last '>' line was blank
            var in_bq_para = false; // track if we're in a paragraph inside the blockquote
            while (i < lines.len) {
                if (parsers.tryBlockquoteLine(allocator, lines[i])) |cl| {
                    if (bq_buf.items.len > 0) try bq_buf.append(allocator, '\n');
                    try bq_buf.appendSlice(allocator, cl);
                    // Track whether this quoted line is blank (e.g. ">" or "> ")
                    last_was_blank_bq = trimLine(cl).len == 0;
                    // Track paragraph state: a non-blank quoted line after a blank one
                    // starts fresh, a blank quoted line ends the current paragraph
                    if (last_was_blank_bq) {
                        in_bq_para = false;
                    } else {
                        // Check if this line starts a new block construct that
                        // cannot contain paragraph continuation (code blocks, etc.)
                        const cl_trimmed = trimLine(cl);
                        if (cl_trimmed.len > 0 and cl_trimmed[0] == '#') {
                            in_bq_para = false; // ATX heading
                        } else if (isThematicBreak(cl)) {
                            in_bq_para = false;
                        } else if (parsers.tryFenceStart(cl) != null) {
                            in_bq_para = false;
                        } else if (parsers.tryIndentedCode(cl) != null and !in_bq_para) {
                            // Indented code can only start when not already in a paragraph
                            in_bq_para = false;
                        } else {
                            // Paragraph text, list items (which contain paragraphs),
                            // nested blockquotes (which can contain paragraphs) —
                            // all allow lazy continuation at the outermost level.
                            in_bq_para = true;
                        }
                    }
                    i += 1;
                } else if (!isBlankLine(lines[i])) {
                    // Lazy continuation: only allowed for paragraph continuation.
                    // After a blank ">" line or non-paragraph block, no lazy continuation.
                    if (last_was_blank_bq or !in_bq_para) break;
                    const lazy_t = trimLine(lines[i]);
                    if (lazy_t[0] == '#') break; // ATX heading
                    if (isThematicBreak(lines[i])) break;
                    if (bulletListContentColumn(lines[i]) != null) break;
                    if (orderedListContentColumn(lines[i]) != null) break;
                    if (parsers.tryFenceStart(lines[i]) != null) break;
                    if (isHtmlBlockStart(lazy_t)) break;
                    if (bq_buf.items.len > 0) try bq_buf.append(allocator, '\n');
                    // Append lazy continuation as-is (preserving indentation).
                    // The inner parser needs the raw indentation to determine
                    // whether the line is paragraph continuation text vs a
                    // new block construct (e.g. 4+ spaces = can't start a list).
                    const nocr = mem.trimRight(u8, lines[i], "\r");
                    try bq_buf.appendSlice(allocator, nocr);
                    // Track if any lazy continuation line looks like a setext underline
                    if (isSetextEqLine(lines[i]) or isSetextDashLine(lines[i])) {
                        has_lazy_setext_line = true;
                    }
                    i += 1;
                } else break;
            }
            const bq_str = try bq_buf.toOwnedSlice(allocator);
            defer allocator.free(bq_str);
            var inner = init();
            inner.has_lazy_setext = has_lazy_setext_line;
            var inner_doc = try inner.parseMarkdownWithRefs(allocator, bq_str, ref_map);
            var bq = AST.Blockquote.init(allocator);
            for (inner_doc.children.items) |block| try bq.children.append(allocator, block);
            inner_doc.children.deinit(allocator);
            inner_doc.children = std.ArrayList(AST.Block){};
            try doc.children.append(allocator, .{ .blockquote = bq });
            continue;
        }

        // Unordered list
        if (bulletListContentColumn(raw)) |first| {
            const result = try parseList(allocator, lines, i, ref_map, .{ .list_type = .unordered, .marker = first.marker, .delimiter = 0, .start_num = 0 });
            try doc.children.append(allocator, .{ .list = result.list });
            i = result.next_line;
            continue;
        }

        // Ordered list
        if (orderedListContentColumn(raw)) |first| {
            const result = try parseList(allocator, lines, i, ref_map, .{ .list_type = .ordered, .marker = 0, .delimiter = first.delimiter, .start_num = first.num });
            try doc.children.append(allocator, .{ .list = result.list });
            i = result.next_line;
            continue;
        }

        // HTML block (CommonMark §4.6)
        if (isHtmlBlockStart(t)) {
            var html_buf = std.ArrayList(u8){};
            const block_type = htmlBlockEndCondition(t);
            while (i < lines.len) {
                if (html_buf.items.len > 0) try html_buf.append(allocator, '\n');
                try html_buf.appendSlice(allocator, lines[i]);
                i += 1;
                switch (block_type) {
                    .type1, .type2, .type3, .type4, .type5 => {
                        // Types 1-5 end when their specific end marker is found in the line
                        if (htmlBlockTypeEndFound(lines[i - 1], block_type)) break;
                    },
                    .type6, .type7 => {
                        // Types 6/7 end at a blank line
                        if (i < lines.len and isBlankLine(lines[i])) break;
                    },
                }
            }
            try html_buf.append(allocator, '\n');
            try doc.children.append(allocator, .{ .html_block = .{ .content = try html_buf.toOwnedSlice(allocator) } });
            continue;
        }

        // Footnote definition
        if (parsers.tryFootnoteDef(allocator, t)) |fd| {
            var fn_def = AST.FootnoteDefinition.init(allocator, fd.label);
            var para = AST.Paragraph.init(allocator);
            const fn_pc = try allocator.dupe(u8, fd.content);
            para.inline_source = fn_pc;
            try appendInlines(allocator, &para.children, fn_pc, ref_map);
            try fn_def.children.append(allocator, .{ .paragraph = para });
            try doc.children.append(allocator, .{ .footnote_definition = fn_def });
            i += 1;
            continue;
        }

        // GFM table (header line + delimiter line)
        {
            if (try tryTableStart(allocator, lines, i, ref_map)) |tres| {
                try doc.children.append(allocator, .{ .table = tres.table });
                i = tres.next_line;
                continue;
            }
        }

        // Paragraph (possibly setext heading)
        {
            var is_first = true;
            var para_buf = std.ArrayList(u8){};
            while (i < lines.len) {
                const lr = lines[i];
                const lt = trimLine(lr);
                if (lt.len == 0) break;
                if (!is_first and !self.has_lazy_setext and (isSetextEqLine(lr) or isSetextDashLine(lr))) break;
                if (!is_first and isParaBreak(allocator, lt, lr)) break;
                const next_setext = !self.has_lazy_setext and i + 1 < lines.len and (isSetextEqLine(lines[i + 1]) or isSetextDashLine(lines[i + 1]));
                if (!is_first) try para_buf.append(allocator, '\n');
                is_first = false;
                // Use left-trimmed content to preserve trailing spaces for code spans.
                // Trailing spaces at the end of the paragraph are stripped below.
                const nocr = mem.trimRight(u8, lr, "\r");
                const left_trimmed = mem.trimLeft(u8, nocr, " \t");
                try para_buf.appendSlice(allocator, left_trimmed);
                i += 1;
                if (next_setext) break;
            }
            var para = AST.Paragraph.init(allocator);
            // Check if next line is a setext underline before parsing inlines
            const is_setext = !self.has_lazy_setext and i < lines.len and (isSetextEqLine(lines[i]) or isSetextDashLine(lines[i]));
            if (para_buf.items.len > 0) {
                // Trim trailing whitespace from paragraph content
                // (hard line breaks at end of paragraph are ignored per CommonMark)
                var content = para_buf.items;
                while (content.len > 0 and (content[content.len - 1] == ' ' or content[content.len - 1] == '\t')) {
                    content = content[0 .. content.len - 1];
                }
                const pc = try allocator.dupe(u8, content);
                para_buf.deinit(allocator);
                try appendInlines(allocator, &para.children, pc, ref_map);
                para.inline_source = pc;
            }
            if (is_setext and para.children.items.len > 0) {
                const st = trimLine(lines[i]);
                const level: u8 = if (isSetextEqLine(st)) 1 else 2;
                var heading = AST.Heading.init(allocator, level);
                for (para.children.items) |item| try heading.children.append(allocator, item);
                para.children.clearRetainingCapacity();
                // Transfer inline_source ownership: heading text nodes borrow
                // from pc, so store it in the first child for the heading to
                // keep alive.  We use heading_source on Heading for this.
                heading.inline_source = para.inline_source;
                para.inline_source = null;
                para.deinit(allocator);
                try doc.children.append(allocator, .{ .heading = heading });
                i += 1;
                continue;
            }
            if (para.children.items.len > 0)
                try doc.children.append(allocator, .{ .paragraph = para })
            else
                para.deinit(allocator);
        }
    }
    return doc;
}

fn parseTableDelimiter(line: []const u8, col_count: usize) ?[]AST.TableAlignment {
    var aligns: [64]AST.TableAlignment = undefined; // hard upper bound; GFM tables are usually small
    if (col_count > aligns.len) return null;

    var i: usize = 0;
    var col: usize = 0;

    const t = trimLine(line);
    if (t.len == 0) return null;

    while (i < t.len and col < col_count) {
        // Skip leading spaces and optional leading '|'
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
        if (i < t.len and t[i] == '|') i += 1;
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
        if (i >= t.len) break;

        // Parse one delimiter cell: optional ':', 1+ '-', optional ':'
        var left_colon = false;
        var right_colon = false;

        if (t[i] == ':') {
            left_colon = true;
            i += 1;
        }

        var dash_count: usize = 0;
        while (i < t.len and t[i] == '-') : (i += 1) dash_count += 1;
        if (dash_count < 1) return null;

        if (i < t.len and t[i] == ':') {
            right_colon = true;
            i += 1;
        }

        // Consume trailing spaces up to next '|' or end
        while (i < t.len and t[i] != '|' and t[i] != '\n' and t[i] != '\r') i += 1;
        if (i < t.len and t[i] == '|') i += 1;

        const tab_align: AST.TableAlignment = if (left_colon and right_colon)
            .center
        else if (left_colon)
            .left
        else if (right_colon)
            .right
        else
            .none;

        aligns[col] = tab_align;
        col += 1;
    }

    if (col == 0) return null;

    // Fill missing columns with .none if fewer delimiters than header cells
    while (col < col_count) : (col += 1) aligns[col] = .none;

    return &aligns;
}

fn splitTableRow(line: []const u8, col_count: usize) []const []const u8 {
    // Work on trimmed line, but preserve interior spaces for inline parsing
    const t = trimLine(line);
    var cells = std.ArrayList([]const u8){};

    var i: usize = 0;

    // Optional leading '|'
    if (i < t.len and t[i] == '|') i += 1;

    while (cells.items.len < col_count and i <= t.len) {
        const start = i;
        while (i < t.len and t[i] != '|') i += 1;
        const cell = mem.trim(u8, t[start..i], " \t");
        cells.append(std.heap.page_allocator, cell) catch break; // temp alloc, caller will dupe

        if (i < t.len and t[i] == '|') i += 1 else break;
    }

    // Pad up to col_count with empty cells
    while (cells.items.len < col_count)
        cells.append(std.heap.page_allocator, "") catch break;

    return cells.toOwnedSlice(std.heap.page_allocator) catch &[_][]const u8{};
}

const TableParseResult = struct {
    table: AST.Table,
    next_line: usize,
};

fn parseTableRow(
    allocator: Allocator,
    ref_map: ?*const RefMap,
    alignments: []const AST.TableAlignment,
    row_line: []const u8,
    table_row: *AST.TableRow,
) !void {
    const cols = alignments.len;
    const raw_cells = splitTableRow(row_line, cols);

    for (raw_cells, 0..) |cell_src, idx| {
        var cell = AST.TableCell.init(allocator);
        const dup = try allocator.dupe(u8, cell_src);
        cell.inline_source = dup;
        try appendInlines(allocator, &cell.children, dup, ref_map);
        try table_row.cells.append(allocator, cell);
        if (idx + 1 == cols) break;
    }
}

fn tryTableStart(
    allocator: Allocator,
    lines: []const []const u8,
    start: usize,
    ref_map: ?*const RefMap,
) !?TableParseResult {
    if (start + 1 >= lines.len) return null;

    const header_line = lines[start];
    const delim_line = lines[start + 1];

    // Header must contain at least one '|'
    if (mem.indexOfScalar(u8, header_line, '|') == null) return null;

    // Count header columns by splitting on '|'
    var header_cols: usize = 0;
    {
        const t = trimLine(header_line);
        var i: usize = 0;
        if (i < t.len and t[i] == '|') i += 1;
        while (i <= t.len) {
            header_cols += 1;
            while (i < t.len and t[i] != '|') i += 1;
            if (i < t.len and t[i] == '|') i += 1 else break;
        }
    }

    if (header_cols == 0) return null;

    const align_buf = try allocator.alloc(AST.TableAlignment, header_cols);
    defer allocator.free(align_buf);

    if (parseTableDelimiter(delim_line, header_cols)) |tmp| {
        // copy alignments into owned buffer
        for (align_buf, 0..) |*dst, i| dst.* = tmp[i];
    } else return null;

    var table = AST.Table.init(allocator);
    // install alignments
    for (align_buf) |a| try table.alignments.append(allocator, a);

    // Header row
    try parseTableRow(allocator, ref_map, table.alignments.items, header_line, &table.header);

    // Body rows
    var i = start + 2;
    while (i < lines.len) : (i += 1) {
        const raw = lines[i];
        const t = trimLine(raw);
        if (t.len == 0) break;
        if (isStandaloneBlockStart(allocator, raw)) break;

        var row = AST.TableRow.init(allocator);
        try parseTableRow(allocator, ref_map, table.alignments.items, raw, &row);
        try table.body.append(allocator, row);
    }

    return .{ .table = table, .next_line = i };
}

test {
    _ = @import("test.zig");
    tst.refAllDecls(@This());
}
