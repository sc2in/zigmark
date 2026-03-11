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
const std = @import("std");
const Allocator = std.mem.Allocator;
const tst = std.testing;
const mem = std.mem;

const mecha = @import("mecha");

const AST = @import("ast.zig");

// ── Result types for mecha-based parsers (kept for API compat) ──────────────

const HeadingResult = struct { level: u8, content: []const u8 };
const LinkResult = struct { text: []const u8, url: []const u8 };
const EmphasisResult = struct { marker: u8, content: []const u8 };
const FootnoteRefResult = struct { label: []const u8 };
const FootnoteDefResult = struct { label: []const u8, content: []const u8 };
const ListItemResult = struct { marker: u8, content: []const u8 };
const BlockquoteResult = struct { content: []const u8 };

// ── Mecha parsers namespace (backward compat) ─────────────────────────────────

/// Low-level `mecha` parser combinators exposed for advanced use or testing.
///
/// Most callers should use `parseMarkdown` instead.
pub const parsers = struct {
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

    pub fn atx_heading(_: std.mem.Allocator) mecha.Parser(HeadingResult) {
        return mecha.combine(.{
            hash.many(.{ .collect = false, .min = 1, .max = 6 }),
            space,
            mecha.many(mecha.oneOf(.{
                text_char,             mecha.ascii.char('*'), mecha.ascii.char('_'),
                mecha.ascii.char('['), mecha.ascii.char(']'), mecha.ascii.char('`'),
            }), .{ .collect = false }).asStr(),
            line_ending.opt(),
        }).map(struct {
            fn build(r: anytype) HeadingResult {
                return .{ .level = @intCast(r[0].len), .content = std.mem.trim(u8, r[2], " \t#") };
            }
        }.build);
    }

    pub fn in_line_link(_: std.mem.Allocator) mecha.Parser(LinkResult) {
        return mecha.combine(.{
            lbracket,
            mecha.many(mecha.oneOf(.{
                text_char, mecha.ascii.char('*'), mecha.ascii.char('_'), mecha.ascii.char('`'),
            }), .{ .collect = false }).asStr(),
            rbracket,
            lparen,
            url_char.many(.{ .collect = false, .min = 1 }).asStr(),
            rparen,
        }).map(struct {
            fn build(r: anytype) LinkResult {
                return .{ .text = r[1], .url = r[4] };
            }
        }.build);
    }

    pub fn emphasis(_: std.mem.Allocator) mecha.Parser(EmphasisResult) {
        const ast_emp = mecha.combine(.{
            asterisk,
            mecha.many(mecha.oneOf(.{
                text_char,             mecha.ascii.char('_'), mecha.ascii.char('['),
                mecha.ascii.char(']'), mecha.ascii.char('`'),
            }), .{ .collect = false }).asStr(),
            asterisk,
        }).map(struct {
            fn build(r: anytype) EmphasisResult {
                return .{ .marker = '*', .content = r[1] };
            }
        }.build);
        const und_emp = mecha.combine(.{
            underscore,
            mecha.many(mecha.oneOf(.{
                text_char,             mecha.ascii.char('*'), mecha.ascii.char('['),
                mecha.ascii.char(']'), mecha.ascii.char('`'),
            }), .{ .collect = false }).asStr(),
            underscore,
        }).map(struct {
            fn build(r: anytype) EmphasisResult {
                return .{ .marker = '_', .content = r[1] };
            }
        }.build);
        return mecha.oneOf(.{ ast_emp, und_emp });
    }

    pub fn strong(_: std.mem.Allocator) mecha.Parser(EmphasisResult) {
        const ast_str = mecha.combine(.{
            asterisk, asterisk,
            mecha.many(mecha.oneOf(.{
                text_char,             mecha.ascii.char('_'), mecha.ascii.char('['),
                mecha.ascii.char(']'), mecha.ascii.char('`'),
            }), .{ .collect = false }).asStr(),
            asterisk,
            asterisk,
        }).map(struct {
            fn build(r: anytype) EmphasisResult {
                return .{ .marker = '*', .content = r[2] };
            }
        }.build);
        const und_str = mecha.combine(.{
            underscore, underscore,
            mecha.many(mecha.oneOf(.{
                text_char,             mecha.ascii.char('*'), mecha.ascii.char('['),
                mecha.ascii.char(']'), mecha.ascii.char('`'),
            }), .{ .collect = false }).asStr(),
            underscore,
            underscore,
        }).map(struct {
            fn build(r: anytype) EmphasisResult {
                return .{ .marker = '_', .content = r[2] };
            }
        }.build);
        return mecha.oneOf(.{ ast_str, und_str });
    }

    pub fn footnote_reference(_: std.mem.Allocator) mecha.Parser(FootnoteRefResult) {
        return mecha.combine(.{
            lbracket,                                                                             caret,
            mecha.many(mecha.oneOf(.{ letter, digit }), .{ .collect = false, .min = 1 }).asStr(), rbracket,
        }).map(struct {
            fn build(r: anytype) FootnoteRefResult {
                return .{ .label = r[2] };
            }
        }.build);
    }

    pub fn footnote_definition(_: std.mem.Allocator) mecha.Parser(FootnoteDefResult) {
        return mecha.combine(.{
            lbracket,                                                                             caret,
            mecha.many(mecha.oneOf(.{ letter, digit }), .{ .collect = false, .min = 1 }).asStr(), rbracket,
            colon,                                                                                space,
            mecha.rest.asStr(),
        }).map(struct {
            fn build(r: anytype) FootnoteDefResult {
                return .{ .label = r[2], .content = std.mem.trim(u8, r[6], " \t\n\r") };
            }
        }.build);
    }

    pub fn bullet_list_item(_: std.mem.Allocator) mecha.Parser(ListItemResult) {
        return mecha.combine(.{
            mecha.oneOf(.{ dash, asterisk, plus }), space, mecha.rest.asStr(),
        }).map(struct {
            fn build(r: anytype) ListItemResult {
                return .{ .marker = r[0], .content = std.mem.trim(u8, r[2], " \t\n\r") };
            }
        }.build);
    }

    pub fn blockquote_line(_: std.mem.Allocator) mecha.Parser(BlockquoteResult) {
        return mecha.combine(.{ gt, space.opt(), mecha.rest.asStr() }).map(struct {
            fn build(r: anytype) BlockquoteResult {
                return .{ .content = std.mem.trim(u8, r[2], " \t\n\r") };
            }
        }.build);
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

const FenceInfo = struct { char: u8, len: usize, info: []const u8 };

fn parseFenceStart(line: []const u8) ?FenceInfo {
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

fn isFenceEnd(line: []const u8, fence: FenceInfo) bool {
    const t = trimLine(line);
    var n: usize = 0;
    while (n < t.len and t[n] == fence.char) n += 1;
    if (n < fence.len) return false;
    return mem.trim(u8, t[n..], " \t").len == 0;
}

fn parseAtxHeading(line: []const u8) ?struct { level: u8, content: []const u8 } {
    const t = trimLine(line);
    if (t.len == 0 or t[0] != '#') return null;
    var level: u8 = 0;
    var i: usize = 0;
    while (i < t.len and t[i] == '#') {
        level += 1;
        i += 1;
    }
    if (level > 6) return null;
    if (i == t.len) return .{ .level = level, .content = "" };
    if (t[i] != ' ' and t[i] != '\t') return null;
    i += 1;
    return .{ .level = level, .content = mem.trim(u8, t[i..], " \t#") };
}

fn parseBulletListMarker(line: []const u8) ?struct { marker: u8, content: []const u8 } {
    var s: usize = 0;
    while (s < 3 and s < line.len and line[s] == ' ') s += 1;
    const t = line[s..];
    if (t.len < 2) return null;
    const c = t[0];
    if (c != '-' and c != '*' and c != '+') return null;
    if (t[1] != ' ' and t[1] != '\t') return null;
    return .{ .marker = c, .content = mem.trimLeft(u8, t[2..], " \t") };
}

const OrderedMarker = struct { num: u32, delimiter: u8, content: []const u8 };

fn parseOrderedListMarker(line: []const u8) ?OrderedMarker {
    var s: usize = 0;
    while (s < 3 and s < line.len and line[s] == ' ') s += 1;
    const t = line[s..];
    var i: usize = 0;
    while (i < t.len and t[i] >= '0' and t[i] <= '9') i += 1;
    if (i == 0 or i > 9) return null;
    if (i >= t.len) return null;
    const delim = t[i];
    if (delim != '.' and delim != ')') return null;
    if (i + 1 >= t.len) return null;
    if (t[i + 1] != ' ' and t[i + 1] != '\t') return null;
    const num = std.fmt.parseInt(u32, t[0..i], 10) catch return null;
    return .{ .num = num, .delimiter = delim, .content = mem.trimLeft(u8, t[i + 2 ..], " \t") };
}

fn parseBlockquoteMarker(line: []const u8) ?[]const u8 {
    const t = mem.trimLeft(u8, line, " \t");
    if (t.len == 0 or t[0] != '>') return null;
    if (t.len == 1) return "";
    if (t[1] == ' ' or t[1] == '\t') return t[2..];
    return t[1..];
}

fn parseIndentedCode(line: []const u8) ?[]const u8 {
    if (mem.startsWith(u8, line, "    ")) return line[4..];
    if (mem.startsWith(u8, line, "\t")) return line[1..];
    return null;
}

fn parseFootnoteDef(line: []const u8) ?struct { label: []const u8, content: []const u8 } {
    const t = trimLine(line);
    if (!mem.startsWith(u8, t, "[^")) return null;
    const bc = mem.indexOfScalar(u8, t, ']') orelse return null;
    if (bc + 1 >= t.len or t[bc + 1] != ':') return null;
    const label = t[2..bc];
    if (label.len == 0) return null;
    return .{ .label = label, .content = mem.trim(u8, t[bc + 2 ..], " \t") };
}

/// Returns true when `t` (trimmed) starts a block that terminates a paragraph,
/// EXCEPT for thematic-break-like lines which may be setext underlines.
fn isParaBreak(t: []const u8, raw: []const u8) bool {
    if (t.len == 0) return true;
    if (t[0] == '#') return true;
    if (t[0] == '>') return true;
    if (parseBulletListMarker(t) != null) return true;
    if (parseOrderedListMarker(t) != null) return true;
    if (parseFenceStart(raw) != null) return true;
    if (parseIndentedCode(raw) != null) return true;
    if (parseFootnoteDef(t) != null) return true;
    if (isLinkRefDefLine(raw)) return true;
    return false;
}

/// Quick check: does this line look like it starts a link reference definition?
fn isLinkRefDefLine(line: []const u8) bool {
    const t = mem.trimLeft(u8, line, " ");
    if (t.len < 4) return false; // minimum: [x]:y
    if (t[0] != '[') return false;
    // Must not start with [^ (that's a footnote def)
    if (t.len > 1 and t[1] == '^') return false;
    // Check if this line parses as a valid ref def (possibly with continuation)
    return parseLinkRefDef(line) != null;
}

/// Quick check: is this line the start of a standalone block element?
fn isStandaloneBlockStart(line: []const u8) bool {
    const t = trimLine(line);
    if (t.len == 0) return true;
    if (t[0] == '#') return true;
    if (t[0] == '>') return true;
    if (isThematicBreak(t)) return true;
    if (parseBulletListMarker(t) != null) return true;
    if (parseOrderedListMarker(t) != null) return true;
    if (parseFenceStart(line) != null) return true;
    if (isLinkRefDefLine(line)) return true;
    return false;
}

// ── Link reference definitions ────────────────────────────────────────────────

/// Stores resolved link reference definitions: label → (url, title)
const RefMap = std.StringHashMap(struct { url: []const u8, title: ?[]const u8 });

/// Case-insensitive label normalization: collapse whitespace, lowercase ASCII.
fn normalizeLabel(allocator: Allocator, label: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8){};
    var prev_ws = true; // trim leading
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
    // trim trailing space
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') _ = buf.pop();
    return buf.toOwnedSlice(allocator);
}

/// Parse a link reference definition line.
/// Format: [label]: <destination> "title"
/// Returns null if not a valid definition.
fn parseLinkRefDef(line: []const u8) ?struct { label: []const u8, url: []const u8, title: ?[]const u8, consumed: usize } {
    var pos: usize = 0;
    // Up to 3 spaces of indentation
    while (pos < 3 and pos < line.len and line[pos] == ' ') pos += 1;
    if (pos >= line.len or line[pos] != '[') return null;
    pos += 1;
    const label_start = pos;
    // Find closing ']' — no unescaped '[' allowed
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
    // Check all whitespace label
    var all_ws = true;
    for (label) |c| if (c != ' ' and c != '\t' and c != '\n') {
        all_ws = false;
        break;
    };
    if (all_ws) return null;

    pos += 1; // skip ']'
    if (pos >= line.len or line[pos] != ':') return null;
    pos += 1; // skip ':'

    // Skip optional whitespace (including up to one newline for multi-line defs)
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    if (pos < line.len and line[pos] == '\n') {
        pos += 1;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    }
    if (pos >= line.len) return null;

    // Parse destination
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

    // Skip optional whitespace
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    if (pos < line.len and line[pos] == '\n') {
        pos += 1;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    }

    // Optional title
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

    // After title, only whitespace allowed to end of line
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    if (pos < line.len and line[pos] != '\n') {
        // Trailing content that isn't whitespace → not a valid ref def
        return null;
    }

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
/// Handles:
///  - Angle-bracket destinations: [text](<url with spaces>)
///  - Nested parentheses in bare destinations (up to 1 level)
///  - Backslash escapes in destinations
///  - Three title delimiter styles: "title", 'title', (title)
///  - Spaces disallowed in bare (non-angle-bracket) destinations
///  - Multi-line whitespace between url and title
fn tryParseLink(input: []const u8, start: usize) ?struct {
    text: []const u8,
    url: []const u8,
    title: ?[]const u8,
    end: usize,
} {
    if (start >= input.len or input[start] != '[') return null;

    // Find closing ']', handling backslash escapes
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

    // Parse the contents inside parentheses
    var pos = be + 2;

    // Skip optional whitespace (including newlines) after '('
    while (pos < input.len and (input[pos] == ' ' or input[pos] == '\t' or input[pos] == '\n' or input[pos] == '\r')) pos += 1;
    if (pos >= input.len) return null;

    // Parse destination
    var url: []const u8 = undefined;
    if (pos < input.len and input[pos] == '<') {
        // Angle-bracket destination
        const url_start = pos + 1;
        pos += 1;
        while (pos < input.len) {
            if (input[pos] == '\\' and pos + 1 < input.len) {
                pos += 2; // skip escaped char
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
        pos += 1; // skip '>'
    } else if (pos < input.len and input[pos] == ')') {
        // Empty destination
        url = "";
    } else {
        // Bare destination — no spaces allowed, handle nested parens and backslash escapes
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
            } else if (ch <= 0x1f) { // control chars
                return null;
            } else {
                pos += 1;
            }
        }
        if (paren_depth != 0) return null;
        url = input[url_start..pos];
    }

    // Skip optional whitespace between destination and title
    while (pos < input.len and (input[pos] == ' ' or input[pos] == '\t' or input[pos] == '\n' or input[pos] == '\r')) pos += 1;
    if (pos >= input.len) return null;

    // Check for title or closing paren
    var title: ?[]const u8 = null;
    if (input[pos] == ')') {
        // No title
        return .{ .text = link_text, .url = url, .title = title, .end = pos + 1 };
    }

    // Try to parse title with ", ', or ( delimiters
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
    pos += 1; // skip closing quote

    // Skip optional whitespace after title
    while (pos < input.len and (input[pos] == ' ' or input[pos] == '\t' or input[pos] == '\n' or input[pos] == '\r')) pos += 1;
    if (pos >= input.len or input[pos] != ')') return null;

    return .{ .text = link_text, .url = url, .title = title, .end = pos + 1 };
}

// ── CommonMark delimiter-based emphasis algorithm ─────────────────────────────

/// Check if a byte is Unicode whitespace (simplified: ASCII ws + common Unicode ws).
fn isUnicodeWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c or c == 0x0b;
}

/// Check if position is a Unicode punctuation character.
/// For multi-byte UTF-8, we check if the character falls in common Unicode
/// punctuation categories. Non-ASCII letters (like Cyrillic) are NOT punctuation.
fn isUnicodePunct(input: []const u8, pos: usize) bool {
    if (pos >= input.len) return false;
    const c = input[pos];
    // ASCII punctuation
    if (isAsciiPunct(c)) return true;
    // For multi-byte UTF-8: we need to check if it's a Unicode punctuation char.
    // Common Unicode punctuation ranges include:
    // - General Punctuation (U+2000-U+206F) - starts with 0xE2 0x80
    // - Supplemental Punctuation (U+2E00-U+2E7F)
    // - CJK Symbols (U+3000-U+303F)
    // Most multi-byte characters that are letters (Cyrillic, CJK, etc.) are NOT punctuation.
    if (c >= 0x80) {
        // Decode the UTF-8 character to determine if it's punctuation
        if (c < 0xC0) return false; // continuation byte, shouldn't start here
        // 2-byte sequences (U+0080 - U+07FF)
        if (c >= 0xC0 and c < 0xE0) {
            if (pos + 1 >= input.len) return false;
            const cp = (@as(u32, c & 0x1F) << 6) | @as(u32, input[pos + 1] & 0x3F);
            // U+00A0-U+00BF contains some punctuation
            return isUnicodeCodepointPunct(cp);
        }
        // 3-byte sequences (U+0800 - U+FFFF)
        if (c >= 0xE0 and c < 0xF0) {
            if (pos + 2 >= input.len) return false;
            const cp = (@as(u32, c & 0x0F) << 12) |
                (@as(u32, input[pos + 1] & 0x3F) << 6) |
                @as(u32, input[pos + 2] & 0x3F);
            return isUnicodeCodepointPunct(cp);
        }
        // 4-byte sequences (U+10000 - U+10FFFF)
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

/// Check if a Unicode codepoint is in a punctuation category.
fn isUnicodeCodepointPunct(cp: u32) bool {
    // Pc: Connector Punctuation
    if (cp == 0x005F) return true; // underscore (already covered by ASCII)
    if (cp >= 0x203F and cp <= 0x2040) return true;
    if (cp == 0x2054) return true;
    if (cp == 0xFE33 or cp == 0xFE34) return true;
    if (cp >= 0xFE4D and cp <= 0xFE4F) return true;
    if (cp == 0xFF3F) return true;

    // Pd: Dash Punctuation
    if (cp == 0x002D) return true;
    if (cp == 0x058A) return true;
    if (cp == 0x05BE) return true;
    if (cp == 0x1400) return true;
    if (cp == 0x1806) return true;
    if (cp >= 0x2010 and cp <= 0x2015) return true;
    if (cp == 0x2E17 or cp == 0x2E1A) return true;
    if (cp >= 0x2E3A and cp <= 0x2E3B) return true;
    if (cp == 0x2E40) return true;
    if (cp == 0x301C) return true;
    if (cp == 0x3030) return true;
    if (cp == 0x30A0) return true;
    if (cp >= 0xFE31 and cp <= 0xFE32) return true;
    if (cp == 0xFE58) return true;
    if (cp == 0xFE63) return true;
    if (cp == 0xFF0D) return true;

    // Ps: Open Punctuation
    if (cp == 0x0028 or cp == 0x005B or cp == 0x007B) return true;
    if (cp == 0x0F3A or cp == 0x0F3C) return true;
    if (cp == 0x169B) return true;
    if (cp == 0x201A) return true;
    if (cp == 0x201E) return true;
    if (cp == 0x2045) return true;
    if (cp == 0x207D) return true;
    if (cp == 0x208D) return true;
    if (cp == 0x2308 or cp == 0x230A) return true;
    if (cp == 0x2329) return true;
    if (cp >= 0x2768 and cp <= 0x2775 and cp % 2 == 0) return true;
    if (cp == 0x27C5 or cp == 0x27E6 or cp == 0x27E8 or cp == 0x27EA or cp == 0x27EC or cp == 0x27EE) return true;
    if (cp == 0x2983 or cp == 0x2985 or cp == 0x2987 or cp == 0x2989 or cp == 0x298B or cp == 0x298D or cp == 0x298F or cp == 0x2991 or cp == 0x2993 or cp == 0x2995 or cp == 0x2997) return true;
    if (cp == 0x29D8 or cp == 0x29DA or cp == 0x29FC) return true;
    if (cp >= 0x2E22 and cp <= 0x2E28 and cp % 2 == 0) return true;
    if (cp == 0x2E42) return true;
    if (cp == 0x3008 or cp == 0x300A or cp == 0x300C or cp == 0x300E or cp == 0x3010 or cp == 0x3014 or cp == 0x3016 or cp == 0x3018 or cp == 0x301A) return true;
    if (cp == 0x301D) return true;
    if (cp == 0xFD3F) return true;
    if (cp == 0xFE17) return true;
    if (cp == 0xFE35 or cp == 0xFE37 or cp == 0xFE39 or cp == 0xFE3B or cp == 0xFE3D or cp == 0xFE3F or cp == 0xFE41 or cp == 0xFE43) return true;
    if (cp == 0xFE47) return true;
    if (cp == 0xFE59 or cp == 0xFE5B or cp == 0xFE5D) return true;
    if (cp == 0xFF08 or cp == 0xFF3B or cp == 0xFF5B or cp == 0xFF5F or cp == 0xFF62) return true;

    // Pe: Close Punctuation (mirrors of Ps)
    if (cp == 0x0029 or cp == 0x005D or cp == 0x007D) return true;
    if (cp == 0x0F3B or cp == 0x0F3D) return true;
    if (cp == 0x169C) return true;
    if (cp == 0x2046) return true;
    if (cp == 0x207E) return true;
    if (cp == 0x208E) return true;
    if (cp == 0x2309 or cp == 0x230B) return true;
    if (cp == 0x232A) return true;
    if (cp >= 0x2769 and cp <= 0x2775 and cp % 2 == 1) return true;
    if (cp == 0x27C6 or cp == 0x27E7 or cp == 0x27E9 or cp == 0x27EB or cp == 0x27ED or cp == 0x27EF) return true;
    if (cp == 0x2984 or cp == 0x2986 or cp == 0x2988 or cp == 0x298A or cp == 0x298C or cp == 0x298E or cp == 0x2990 or cp == 0x2992 or cp == 0x2994 or cp == 0x2996 or cp == 0x2998) return true;
    if (cp == 0x29D9 or cp == 0x29DB or cp == 0x29FD) return true;
    if (cp >= 0x2E23 and cp <= 0x2E29 and cp % 2 == 1) return true;
    if (cp == 0x3009 or cp == 0x300B or cp == 0x300D or cp == 0x300F or cp == 0x3011 or cp == 0x3015 or cp == 0x3017 or cp == 0x3019 or cp == 0x301B) return true;
    if (cp == 0x301E or cp == 0x301F) return true;
    if (cp == 0xFD3E) return true;
    if (cp == 0xFE18) return true;
    if (cp == 0xFE36 or cp == 0xFE38 or cp == 0xFE3A or cp == 0xFE3C or cp == 0xFE3E or cp == 0xFE40 or cp == 0xFE42 or cp == 0xFE44) return true;
    if (cp == 0xFE48) return true;
    if (cp == 0xFE5A or cp == 0xFE5C or cp == 0xFE5E) return true;
    if (cp == 0xFF09 or cp == 0xFF3D or cp == 0xFF5D or cp == 0xFF60 or cp == 0xFF63) return true;

    // Pi: Initial quote punctuation
    if (cp == 0x00AB) return true;
    if (cp == 0x2018 or cp == 0x201B or cp == 0x201C or cp == 0x201F) return true;
    if (cp == 0x2039) return true;
    if (cp == 0x2E02 or cp == 0x2E04 or cp == 0x2E09 or cp == 0x2E0C or cp == 0x2E1C or cp == 0x2E20) return true;

    // Pf: Final quote punctuation
    if (cp == 0x00BB) return true;
    if (cp == 0x2019 or cp == 0x201D) return true;
    if (cp == 0x203A) return true;
    if (cp == 0x2E03 or cp == 0x2E05 or cp == 0x2E0A or cp == 0x2E0D or cp == 0x2E1D or cp == 0x2E21) return true;

    // Po: Other Punctuation (partial — most common ranges)
    if (cp >= 0x0021 and cp <= 0x0023) return true;
    if (cp >= 0x0025 and cp <= 0x0027) return true;
    if (cp == 0x002A or cp == 0x002C) return true;
    if (cp == 0x002E or cp == 0x002F) return true;
    if (cp == 0x003A or cp == 0x003B) return true;
    if (cp == 0x003F or cp == 0x0040) return true;
    if (cp == 0x005C) return true;
    if (cp == 0x00A1 or cp == 0x00A7) return true;
    if (cp == 0x00B6 or cp == 0x00B7) return true;
    if (cp == 0x00BF) return true;
    if (cp == 0x037E) return true;
    if (cp == 0x0387) return true;
    if (cp >= 0x055A and cp <= 0x055F) return true;
    if (cp == 0x0589) return true;
    if (cp >= 0x05C0 and cp <= 0x05C6) return true;
    if (cp >= 0x0609 and cp <= 0x060A) return true;
    if (cp == 0x060C or cp == 0x060D) return true;
    if (cp == 0x061B) return true;
    if (cp == 0x061D or cp == 0x061E or cp == 0x061F) return true;
    if (cp >= 0x066A and cp <= 0x066D) return true;
    if (cp == 0x06D4) return true;
    if (cp >= 0x2016 and cp <= 0x2017) return true;
    if (cp >= 0x2020 and cp <= 0x2027) return true;
    if (cp >= 0x2030 and cp <= 0x2038) return true;
    if (cp >= 0x203B and cp <= 0x203E) return true;
    if (cp >= 0x2041 and cp <= 0x2043) return true;
    if (cp >= 0x2047 and cp <= 0x2051) return true;
    if (cp == 0x2053) return true;
    if (cp >= 0x2055 and cp <= 0x205E) return true;
    if (cp >= 0x2CF9 and cp <= 0x2CFC) return true;
    if (cp == 0x2CFE or cp == 0x2CFF) return true;
    if (cp == 0x2E00 or cp == 0x2E01) return true;
    if (cp >= 0x3001 and cp <= 0x3003) return true;
    if (cp == 0x303D) return true;

    // Sm: Math symbols (these count as punctuation for CommonMark)
    // Sc: Currency symbols
    // Sk: Modifier symbols
    // So: Other symbols
    // All symbols count as punctuation per CommonMark spec
    if (cp >= 0x0024 and cp <= 0x0024) return true; // $
    if (cp == 0x002B) return true; // +
    if (cp >= 0x003C and cp <= 0x003E) return true; // < = >
    if (cp == 0x005E) return true; // ^
    if (cp == 0x0060) return true; // `
    if (cp == 0x007C) return true; // |
    if (cp == 0x007E) return true; // ~
    if (cp == 0x00A2 or cp == 0x00A3 or cp == 0x00A4 or cp == 0x00A5) return true; // ¢£¤¥
    if (cp == 0x00A6 or cp == 0x00A8 or cp == 0x00A9) return true;
    if (cp == 0x00AC) return true;
    if (cp == 0x00AE or cp == 0x00AF) return true;
    if (cp == 0x00B0 or cp == 0x00B1) return true;
    if (cp == 0x00B4) return true;
    if (cp == 0x00B8) return true;
    if (cp == 0x00D7) return true;
    if (cp == 0x00F7) return true;
    if (cp >= 0x2190 and cp <= 0x23FF) return true; // Arrows, Math operators, etc.
    if (cp >= 0x2500 and cp <= 0x257F) return true; // Box drawing
    if (cp >= 0x2580 and cp <= 0x259F) return true; // Block elements
    if (cp >= 0x25A0 and cp <= 0x25FF) return true; // Geometric shapes
    if (cp >= 0x2600 and cp <= 0x26FF) return true; // Misc symbols
    if (cp >= 0x2700 and cp <= 0x27BF) return true; // Dingbats

    return false;
}

/// Determine if a delimiter run starting at `run_start` with length `run_len`
/// is left-flanking per CommonMark §6.2 rule 1.
fn isLeftFlanking(input: []const u8, run_start: usize, run_len: usize) bool {
    const run_end = run_start + run_len;
    // (1) Not followed by Unicode whitespace
    if (run_end >= input.len) return false;
    if (isUnicodeWhitespace(input[run_end])) return false;
    // (2a) Not followed by a Unicode punctuation character, OR
    const followed_by_punct = isUnicodePunct(input, run_end);
    if (!followed_by_punct) return true;
    // (2b) preceded by Unicode whitespace or punctuation or beginning of string
    if (run_start == 0) return true;
    if (isUnicodeWhitespace(input[run_start - 1])) return true;
    if (isUnicodePunct(input, run_start - 1)) return true;
    return false;
}

/// Determine if a delimiter run ending at `run_end` (exclusive) starting at `run_start`
/// is right-flanking per CommonMark §6.2 rule 2.
fn isRightFlanking(input: []const u8, run_start: usize, run_len: usize) bool {
    const run_end = run_start + run_len;
    // (1) Not preceded by Unicode whitespace
    if (run_start == 0) return false;
    if (isUnicodeWhitespace(input[run_start - 1])) return false;
    // (2a) Not preceded by a Unicode punctuation character, OR
    const preceded_by_punct = isUnicodePunct(input, run_start - 1);
    if (!preceded_by_punct) return true;
    // (2b) followed by Unicode whitespace or punctuation or end of string
    if (run_end >= input.len) return true;
    if (isUnicodeWhitespace(input[run_end])) return true;
    if (isUnicodePunct(input, run_end)) return true;
    return false;
}

/// Determines if a delimiter run can open emphasis.
fn canOpen(input: []const u8, marker: u8, run_start: usize, run_len: usize) bool {
    const lf = isLeftFlanking(input, run_start, run_len);
    if (marker == '*') return lf;
    // For '_': left-flanking and (not right-flanking or preceded by punctuation)
    const rf = isRightFlanking(input, run_start, run_len);
    return lf and (!rf or (run_start > 0 and isUnicodePunct(input, run_start - 1)));
}

/// Determines if a delimiter run can close emphasis.
fn canClose(input: []const u8, marker: u8, run_start: usize, run_len: usize) bool {
    const rf = isRightFlanking(input, run_start, run_len);
    if (marker == '*') return rf;
    // For '_': right-flanking and (not left-flanking or followed by punctuation)
    const lf = isLeftFlanking(input, run_start, run_len);
    const run_end = run_start + run_len;
    return rf and (!lf or (run_end < input.len and isUnicodePunct(input, run_end)));
}

/// A delimiter entry in the delimiter stack for the CommonMark emphasis algorithm.
const Delimiter = struct {
    /// Index into the flat inline list where this delimiter's text node sits.
    inline_idx: usize,
    /// Position in the original input.
    input_pos: usize,
    /// Number of delimiter characters remaining (may shrink as we process).
    count: usize,
    /// Original count of the delimiter run.
    orig_count: usize,
    /// The delimiter character ('*' or '_').
    marker: u8,
    /// Can this open emphasis?
    can_open: bool,
    /// Can this close emphasis?
    can_close: bool,
    /// Has this delimiter been used up / deactivated?
    active: bool,
};

fn parseInlineElements(allocator: Allocator, input: []const u8, ref_map: ?*const RefMap) !std.ArrayList(AST.Inline) {
    // Phase 1: Parse into a flat list of inlines + build delimiter stack
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

        // Code span `…`
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
                        // Code span content: collapse internal newlines to spaces
                        // and strip a single leading+trailing space if both present
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
                        // Strip one leading and one trailing space if the content
                        // has both AND is not entirely spaces
                        var final_content: []const u8 = code_content;
                        if (code_content.len >= 2 and code_content[0] == ' ' and code_content[code_content.len - 1] == ' ') {
                            // Check if not all spaces
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
                        // Dupe to arena since code_buf may be freed
                        const duped = try allocator.dupe(u8, final_content);
                        code_buf.deinit(allocator);
                        try inlines.append(allocator, .{ .code_span = .{
                            .content = duped,
                        } });
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

        // Raw HTML tags / Autolinks in inline context
        if (c == '<') {
            // Autolink <uri> or <email> — check FIRST before HTML tags
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
                // Recursively parse alt text for nested images
                const alt_text = try flattenInlineText(allocator, r.text, ref_map);
                try inlines.append(allocator, .{ .image = .{
                    .alt_text = alt_text,
                    .destination = .{ .url = r.url, .title = r.title },
                    .link_type = .in_line,
                } });
                pos = r.end;
                continue;
            }
            // Try image reference links: ![alt][label], ![alt][], ![alt]
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
            // Try inline link [text](url)
            if (tryParseLink(input, pos)) |r| {
                var link = AST.Link.init(allocator, .{ .url = r.url, .title = r.title }, .in_line);
                var nested = try parseInlineElements(allocator, r.text, ref_map);
                defer nested.deinit(allocator);
                for (nested.items) |item| try link.children.append(allocator, item);
                try inlines.append(allocator, .{ .link = link });
                pos = r.end;
                continue;
            }
            // Try reference links: [text][label], [text][], [text]
            if (ref_map) |rm| {
                if (tryParseRefLink(allocator, input, pos, rm)) |result| {
                    try inlines.append(allocator, result.inline_node);
                    pos = result.end;
                    continue;
                }
            }
        }

        // Emphasis/strong delimiter run (* or _)
        if (c == '*' or c == '_') {
            const marker = c;
            const run_start = pos;
            var run_len: usize = 0;
            while (pos + run_len < input.len and input[pos + run_len] == marker) run_len += 1;

            const opens = canOpen(input, marker, run_start, run_len);
            const closes = canClose(input, marker, run_start, run_len);

            // Add as text node; the delimiter processing will convert to emphasis later
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

        // Plain text — gather as much as possible
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
            // Check if the preceding content ends with 2+ spaces (hard break)
            var is_hard = false;
            if (inlines.items.len > 0) {
                switch (inlines.items[inlines.items.len - 1]) {
                    .text => |*txt| {
                        if (txt.content.len >= 2 and
                            txt.content[txt.content.len - 1] == ' ' and
                            txt.content[txt.content.len - 2] == ' ')
                        {
                            is_hard = true;
                            // Trim trailing spaces from the text node
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

    // Phase 2: Process emphasis using the CommonMark algorithm
    try processEmphasis(allocator, &inlines, &delimiters);

    return inlines;
}

/// Flatten inline content to plain text (used for image alt text).
fn flattenInlineText(allocator: Allocator, input: []const u8, ref_map: ?*const RefMap) Allocator.Error![]const u8 {
    _ = ref_map;
    // For image alt text, just return the raw text for now
    // (CommonMark says to extract text content from parsed inlines,
    // but for most cases the raw text suffices)
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

/// Try to parse an HTML tag at position `pos`. Returns end position if found.
fn tryParseHtmlTag(input: []const u8, pos: usize) ?usize {
    if (pos >= input.len or input[pos] != '<') return null;
    // Quick check for HTML-like tags: <tagname ...> or </tagname> or <!-- or <? etc.
    if (pos + 1 >= input.len) return null;
    const next = input[pos + 1];
    // Opening tag: <letter...>
    if ((next >= 'a' and next <= 'z') or (next >= 'A' and next <= 'Z')) {
        var i = pos + 2;
        // Tag name
        while (i < input.len and ((input[i] >= 'a' and input[i] <= 'z') or
            (input[i] >= 'A' and input[i] <= 'Z') or
            (input[i] >= '0' and input[i] <= '9') or input[i] == '-'))
        {
            i += 1;
        }
        // Attributes and closing
        while (i < input.len and input[i] != '>') {
            if (input[i] == '\n') return null; // no newlines in inline HTML tags
            i += 1;
        }
        if (i < input.len and input[i] == '>') return i + 1;
        return null;
    }
    // Closing tag
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
    // HTML comment <!--...-->
    if (pos + 3 < input.len and input[pos + 1] == '!' and input[pos + 2] == '-' and input[pos + 3] == '-') {
        var i = pos + 4;
        while (i + 2 < input.len) {
            if (input[i] == '-' and input[i + 1] == '-' and input[i + 2] == '>') return i + 3;
            i += 1;
        }
        return null;
    }
    // Processing instruction <?...?>
    if (next == '?') {
        var i = pos + 2;
        while (i + 1 < input.len) {
            if (input[i] == '?' and input[i + 1] == '>') return i + 2;
            i += 1;
        }
        return null;
    }
    // CDATA <![CDATA[...]]>
    if (pos + 8 < input.len and mem.startsWith(u8, input[pos..], "<![CDATA[")) {
        var i = pos + 9;
        while (i + 2 < input.len) {
            if (input[i] == ']' and input[i + 1] == ']' and input[i + 2] == '>') return i + 3;
            i += 1;
        }
        return null;
    }
    // Declaration <!LETTER...>
    if (next == '!' and pos + 2 < input.len and ((input[pos + 2] >= 'a' and input[pos + 2] <= 'z') or (input[pos + 2] >= 'A' and input[pos + 2] <= 'Z'))) {
        var i = pos + 3;
        while (i < input.len and input[i] != '>') i += 1;
        if (i < input.len) return i + 1;
        return null;
    }
    return null;
}

/// Try to parse an image reference link: ![alt][label], ![alt][], ![alt]
fn tryParseImageRefLink(allocator: Allocator, input: []const u8, start: usize, rm: *const RefMap) ?struct {
    inline_node: AST.Inline,
    end: usize,
} {
    if (start >= input.len or input[start] != '!' or start + 1 >= input.len or input[start + 1] != '[') return null;
    // Find closing ']' for alt text
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

    // Try full reference ![alt][label]
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

    // Try collapsed ![alt][]
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

    // Try shortcut ![alt]
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

/// Implements the CommonMark "process emphasis" algorithm (§6.4 of the spec).
///
/// This walks the delimiter stack looking for closers, then finds matching
/// openers and wraps the intervening inline nodes in Emphasis or Strong nodes.
fn processEmphasis(allocator: Allocator, inlines: *std.ArrayList(AST.Inline), delimiters: *std.ArrayList(Delimiter)) !void {
    // We iterate through potential closers from left to right.
    // For each closer, we look backwards for a matching opener.
    var closer_idx: usize = 0;
    while (closer_idx < delimiters.items.len) {
        var closer = &delimiters.items[closer_idx];
        if (!closer.active or !closer.can_close) {
            closer_idx += 1;
            continue;
        }

        // Look backwards for a matching opener
        var found_opener = false;
        var opener_idx: usize = closer_idx;
        while (opener_idx > 0) {
            opener_idx -= 1;
            const opener = &delimiters.items[opener_idx];
            if (!opener.active or !opener.can_open or opener.marker != closer.marker) continue;

            // "Multiple of 3" rule: if the closer can open or the opener can close,
            // then (opener.orig_count + closer.orig_count) must not be a multiple of 3
            // unless both are multiples of 3.
            if ((opener.can_close or closer.can_open) and
                (opener.orig_count + closer.orig_count) % 3 == 0 and
                opener.orig_count % 3 != 0 and closer.orig_count % 3 != 0)
            {
                continue;
            }

            found_opener = true;

            // Determine how many delimiters to use: 2 for strong, 1 for em
            const use_count: usize = if (closer.count >= 2 and opener.count >= 2) 2 else 1;

            // Build emphasis/strong node
            if (use_count == 2) {
                // Strong
                var strong = AST.Strong.init(allocator, closer.marker);

                // Collect all inlines between opener and closer
                const open_inline = opener.inline_idx;
                const close_inline = closer.inline_idx;

                // Gather children: everything between opener's inline and closer's inline
                var children_start = open_inline + 1;
                var children_end = close_inline;
                var ci = children_start;
                while (ci < children_end) {
                    try strong.children.append(allocator, inlines.items[ci]);
                    ci += 1;
                }

                // Remove consumed inlines and replace with the Strong node
                // First, update the opener's text (trim 2 chars)
                opener.count -= 2;
                closer.count -= 2;

                // Update opener text
                if (opener.count > 0) {
                    const old_content = inlines.items[open_inline].text.content;
                    inlines.items[open_inline] = .{ .text = .{ .content = old_content[0..opener.count] } };
                    children_start = open_inline + 1;
                } else {
                    // Will be removed
                    children_start = open_inline;
                }

                // Update closer text
                if (closer.count > 0) {
                    const old_content = inlines.items[close_inline].text.content;
                    inlines.items[close_inline] = .{ .text = .{ .content = old_content[0..closer.count] } };
                    children_end = close_inline;
                } else {
                    children_end = close_inline + 1;
                }

                // Remove everything from children_start to children_end and insert the Strong node
                const remove_start = if (opener.count > 0) open_inline + 1 else open_inline;
                const remove_end = if (closer.count > 0) close_inline else close_inline + 1;

                // Replace the range with a single Strong node
                if (remove_end > remove_start) {
                    const removed = remove_end - remove_start;
                    inlines.items[remove_start] = .{ .strong = strong };
                    // Shift remaining items
                    if (removed > 1) {
                        var si = remove_start + 1;
                        while (si + removed - 1 < inlines.items.len) {
                            inlines.items[si] = inlines.items[si + removed - 1];
                            si += 1;
                        }
                        inlines.items.len -= removed - 1;
                    }
                    // Fix up delimiter indices
                    for (delimiters.items) |*d| {
                        if (d.inline_idx > remove_start and d.inline_idx < remove_end) {
                            d.active = false;
                        } else if (d.inline_idx >= remove_end) {
                            d.inline_idx -= removed - 1;
                        }
                    }
                    // Fix closer inline_idx
                    closer = &delimiters.items[closer_idx];
                }

                // Deactivate delimiters between opener and closer
                var di = opener_idx + 1;
                while (di < closer_idx) {
                    delimiters.items[di].active = false;
                    di += 1;
                }

                // If opener/closer are exhausted, deactivate
                if (opener.count == 0) opener.active = false;
                if (closer.count == 0) {
                    closer.active = false;
                    closer_idx += 1;
                }
                // Otherwise re-examine the closer (it may have remaining delims)
            } else {
                // Emphasis (use_count == 1)
                var emph = AST.Emphasis.init(allocator, closer.marker);

                const open_inline = opener.inline_idx;
                const close_inline = closer.inline_idx;

                // Gather children
                var ci = open_inline + 1;
                while (ci < close_inline) {
                    try emph.children.append(allocator, inlines.items[ci]);
                    ci += 1;
                }

                opener.count -= 1;
                closer.count -= 1;

                // Update opener text
                if (opener.count > 0) {
                    const old_content = inlines.items[open_inline].text.content;
                    inlines.items[open_inline] = .{ .text = .{ .content = old_content[0..opener.count] } };
                }

                // Update closer text
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
            // No matching opener — if this closer can't open, deactivate it
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

/// Try to parse a reference link starting at `start`:
///   [text][label]  — full reference
///   [text][]       — collapsed reference (label = text)
///   [text]         — shortcut reference (label = text)
fn tryParseRefLink(allocator: Allocator, input: []const u8, start: usize, rm: *const RefMap) ?struct {
    inline_node: AST.Inline,
    end: usize,
} {
    if (start >= input.len or input[start] != '[') return null;

    // Find closing ']' for the link text
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

    // Try full reference [text][label]
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

    // Try collapsed reference [text][]
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

    // Try shortcut reference [text]
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

/// Create a new parser instance.  The parser is stateless; all mutable
/// state lives in the allocator and the returned `AST.Document`.
pub fn init() Self {
    return Self{};
}

/// Release any resources held by the parser (currently a no-op).
pub fn deinit(_: *Self, _: Allocator) void {}

fn appendInlines(allocator: Allocator, dest: *std.ArrayList(AST.Inline), content: []const u8, ref_map: ?*const RefMap) !void {
    var items = try parseInlineElements(allocator, content, ref_map);
    defer items.deinit(allocator);
    for (items.items) |item| try dest.append(allocator, item);
}

/// Parse `input` into an AST Document.  Use an ArenaAllocator; text slices
/// reference `input` (or internally allocated buffers in the same arena).
pub fn parseMarkdown(self: Self, allocator: Allocator, input: []const u8) !AST.Document {
    // First pass: collect link reference definitions
    var ref_map = RefMap.init(allocator);
    defer {
        // Free the HashMap internals and all allocated keys/values.
        // The AST Link nodes have their own dupes of url/title.
        var it = ref_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*.url);
            if (entry.value_ptr.*.title) |t| allocator.free(t);
        }
        ref_map.deinit();
    }
    // Join the full input with \n normalization for ref-def scanning
    try collectLinkRefDefs(allocator, input, &ref_map);

    return self.parseMarkdownWithRefs(allocator, input, &ref_map);
}

/// Scan the input and collect all link reference definitions into the map.
/// First definition wins (per CommonMark spec).
fn collectLinkRefDefs(allocator: Allocator, input: []const u8, ref_map: *RefMap) !void {
    // We scan line-by-line; a ref def can span multiple lines, so we join
    // relevant lines into a single buffer for parsing.
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
        // Try to parse a ref def starting at this line. May need to join
        // with continuation lines (destination on next line, title on next).
        const line = lines[i];

        // Quick check: must start with optional indent + '['
        const trimmed = mem.trimLeft(u8, line, " ");
        if (trimmed.len == 0 or trimmed[0] != '[') {
            i += 1;
            continue;
        }

        // Build a multi-line candidate (up to 3 continuation lines)
        var candidate = std.ArrayList(u8){};
        defer candidate.deinit(allocator);
        try candidate.appendSlice(allocator, line);
        var lines_consumed: usize = 1;
        var j = i + 1;
        while (j < lines.len and lines_consumed < 4) : (j += 1) {
            const next = lines[j];
            if (trimLine(next).len == 0) break; // blank line stops
            try candidate.append(allocator, '\n');
            try candidate.appendSlice(allocator, next);
            lines_consumed += 1;
        }

        if (parseLinkRefDef(candidate.items)) |def| {
            const norm = try normalizeLabel(allocator, def.label);
            // First definition wins
            if (!ref_map.contains(norm)) {
                // Dupe url/title since def slices point into the temporary candidate buffer
                const url_dupe = try allocator.dupe(u8, def.url);
                const title_dupe: ?[]const u8 = if (def.title) |t| try allocator.dupe(u8, t) else null;
                try ref_map.put(norm, .{ .url = url_dupe, .title = title_dupe });
            } else {
                // Duplicate definition; free the unused normalized label
                allocator.free(norm);
            }
        }
        i += 1;
    }
}

/// Internal: parse markdown with an already-populated ref map.
fn parseMarkdownWithRefs(_: Self, allocator: Allocator, input: []const u8, ref_map: *const RefMap) !AST.Document {
    var doc = AST.Document.init(allocator);

    // Collect lines (CRLF / CR / LF normalised to LF by splitting on '\n')
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

    // Skip frontmatter (--- / +++ / %%% delimiters)
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

        // Link reference definition (must check before paragraph)
        if (isLinkRefDefLine(raw)) {
            // Already collected in first pass; skip past it
            i += 1;
            // Skip continuation lines that are part of multi-line ref defs
            while (i < lines.len and !isBlankLine(lines[i]) and
                !isStandaloneBlockStart(lines[i]))
            {
                // Check if this continuation + original forms a valid ref def
                break;
            }
            continue;
        }

        // ATX heading
        if (parseAtxHeading(raw)) |h| {
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
        if (parseIndentedCode(raw)) |_| {
            var buf = std.ArrayList(u8){};
            while (i < lines.len) {
                if (trimLine(lines[i]).len == 0) {
                    var peek = i + 1;
                    while (peek < lines.len and trimLine(lines[peek]).len == 0) peek += 1;
                    if (peek >= lines.len or parseIndentedCode(lines[peek]) == null) break;
                    try buf.append(allocator, '\n');
                    i += 1;
                    continue;
                }
                const stripped = parseIndentedCode(lines[i]) orelse break;
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
        if (parseFenceStart(raw)) |fence| {
            i += 1;
            var buf = std.ArrayList(u8){};
            while (i < lines.len) {
                if (isFenceEnd(lines[i], fence)) {
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
        if (parseBlockquoteMarker(raw)) |_| {
            var bq_buf = std.ArrayList(u8){};
            while (i < lines.len) {
                if (parseBlockquoteMarker(lines[i])) |content_line| {
                    if (bq_buf.items.len > 0) try bq_buf.append(allocator, '\n');
                    try bq_buf.appendSlice(allocator, content_line);
                    i += 1;
                } else if (!isBlankLine(lines[i])) {
                    // lazy continuation
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
            // Transfer block ownership to `bq`.  Reset inner_doc's children to an empty
            // list so that dropping `inner_doc` from the stack doesn't attempt to deinit
            // the same blocks a second time.  The old backing array is intentionally leaked
            // to the arena allocator (no-op free) rather than freed here to avoid touching
            // items that are now owned by `bq`.
            inner_doc.children = std.ArrayList(AST.Block){};
            try doc.children.append(allocator, .{ .blockquote = bq });
            continue;
        }

        // Unordered list
        if (parseBulletListMarker(t)) |first| {
            var list = AST.List.init(allocator, .unordered);
            var loose = false;
            var blank = false;
            while (i < lines.len) {
                const lt = trimLine(lines[i]);
                if (lt.len == 0) {
                    blank = true;
                    i += 1;
                    continue;
                }
                const mi = parseBulletListMarker(lt) orelse break;
                if (mi.marker != first.marker) break;
                if (blank) loose = true;
                blank = false;
                var item = AST.ListItem.init(allocator);
                var para = AST.Paragraph.init(allocator);
                try appendInlines(allocator, &para.children, mi.content, ref_map);
                try item.children.append(allocator, .{ .paragraph = para });
                try list.items.append(allocator, item);
                i += 1;
            }
            list.tight = !loose;
            try doc.children.append(allocator, .{ .list = list });
            continue;
        }

        // Ordered list
        if (parseOrderedListMarker(t)) |first| {
            var list = AST.List.init(allocator, .ordered);
            list.start = first.num;
            var loose = false;
            var blank = false;
            while (i < lines.len) {
                const lt = trimLine(lines[i]);
                if (lt.len == 0) {
                    blank = true;
                    i += 1;
                    continue;
                }
                const mi = parseOrderedListMarker(lt) orelse break;
                if (mi.delimiter != first.delimiter) break;
                if (blank) loose = true;
                blank = false;
                var item = AST.ListItem.init(allocator);
                var para = AST.Paragraph.init(allocator);
                try appendInlines(allocator, &para.children, mi.content, ref_map);
                try item.children.append(allocator, .{ .paragraph = para });
                try list.items.append(allocator, item);
                i += 1;
            }
            list.tight = !loose;
            try doc.children.append(allocator, .{ .list = list });
            continue;
        }

        // Footnote definition
        if (parseFootnoteDef(t)) |fd| {
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

            // Collect all paragraph lines, joining them with \n
            var para_buf = std.ArrayList(u8){};
            var line_count: usize = 0;

            while (i < lines.len) {
                const lr = lines[i];
                const lt = trimLine(lr);

                if (lt.len == 0) break;
                if (!is_first and (isSetextEqLine(lt) or isSetextDashLine(lt))) break;
                if (!is_first and isParaBreak(lt, lr)) break;

                // peek: next line is setext underline → this is the last content line
                const next_setext = blk: {
                    if (i + 1 >= lines.len) break :blk false;
                    const nt = trimLine(lines[i + 1]);
                    break :blk isSetextEqLine(nt) or isSetextDashLine(nt);
                };

                if (!is_first) {
                    // Detect hard line break: 2+ trailing spaces on previous line
                    // We need to check the raw previous line for trailing spaces
                    // For now, add \n and let the inline parser handle hard breaks
                    try para_buf.append(allocator, '\n');
                }
                is_first = false;

                // Check for trailing spaces (hard break marker)
                const lr_nocr = mem.trimRight(u8, lr, "\r");
                const has_hard_break = lr_nocr.len >= 2 and
                    lr_nocr[lr_nocr.len - 1] == ' ' and
                    lr_nocr[lr_nocr.len - 2] == ' ';

                if (has_hard_break) {
                    try para_buf.appendSlice(allocator, mem.trimRight(u8, lt, " "));
                    // Add explicit hard break marker (we'll use \\ + \n)
                    try para_buf.appendSlice(allocator, "  ");
                } else {
                    try para_buf.appendSlice(allocator, lt);
                }

                line_count += 1;
                i += 1;
                if (next_setext) break;
            }

            // Parse the complete paragraph content as a single unit
            var para = AST.Paragraph.init(allocator);
            if (para_buf.items.len > 0) {
                // Convert to owned slice so the memory stays alive for inline slices.
                // The arena allocator will free it when the arena is destroyed.
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

fn ok(s: []const u8) !void {
    var p = init();
    defer p.deinit(tst.allocator);
    var res = try p.parseMarkdown(tst.allocator, s);
    defer res.deinit(tst.allocator);
}

test "heading" {
    try ok("# Heading\n");
    try ok("## Level 2\n");
    try ok("### Level 3\n");
}

test "setext heading" {
    var p = init();
    {
        var doc = try p.parseMarkdown(tst.allocator, "Heading\n=======\n");
        defer doc.deinit(tst.allocator);
        try tst.expect(doc.children.items.len == 1);
        try tst.expect(doc.children.items[0] == .heading);
        try tst.expectEqual(@as(u8, 1), doc.children.items[0].heading.level);
    }
    {
        var doc = try p.parseMarkdown(tst.allocator, "Heading\n-------\n");
        defer doc.deinit(tst.allocator);
        try tst.expect(doc.children.items[0] == .heading);
        try tst.expectEqual(@as(u8, 2), doc.children.items[0].heading.level);
    }
}

test "thematic break" {
    var p = init();
    var doc = try p.parseMarkdown(tst.allocator, "---\n");
    defer doc.deinit(tst.allocator);
    try tst.expectEqual(1, doc.children.items.len);
    try tst.expectEqual(.thematic_break, std.meta.activeTag(doc.children.items[0]));
}

test "paragraph" {
    try ok("Simple paragraph\n");
    try ok("Multiple words\n");
}

test "multi-line paragraph" {
    var p = init();
    var doc = try p.parseMarkdown(tst.allocator, "line one\nline two\n");
    defer doc.deinit(tst.allocator);
    try tst.expect(doc.children.items.len == 1);
    try tst.expect(doc.children.items[0] == .paragraph);
    const children = doc.children.items[0].paragraph.children.items;
    try tst.expect(children.len == 3);
    try tst.expect(children[1] == .soft_break);
}

test "indented code block" {
    var p = init();
    var doc = try p.parseMarkdown(tst.allocator, "    code here\n");
    defer doc.deinit(tst.allocator);
    try tst.expect(doc.children.items.len == 1);
    try tst.expect(doc.children.items[0] == .code_block);
}

test "fenced code block" {
    try ok("```\ncode\n```\n");
    try ok("~~~zig\ncode\n~~~\n");
    {
        var p = init();
        var doc = try p.parseMarkdown(tst.allocator, "```zig\nconst x = 1;\n```\n");
        defer doc.deinit(tst.allocator);
        try tst.expect(doc.children.items.len == 1);
        try tst.expect(doc.children.items[0] == .fenced_code_block);
        try tst.expectEqualStrings("zig", doc.children.items[0].fenced_code_block.language.?);
    }
}

test "list grouping" {
    var p = init();
    var doc = try p.parseMarkdown(tst.allocator, "- item1\n- item2\n- item3\n");
    defer doc.deinit(tst.allocator);
    try tst.expect(doc.children.items.len == 1);
    try tst.expect(doc.children.items[0] == .list);
    try tst.expectEqual(@as(usize, 3), doc.children.items[0].list.items.items.len);
    try tst.expect(doc.children.items[0].list.tight);
}

test "loose list" {
    var p = init();
    var doc = try p.parseMarkdown(tst.allocator, "- item1\n\n- item2\n");
    defer doc.deinit(tst.allocator);
    try tst.expect(doc.children.items[0] == .list);
    try tst.expect(!doc.children.items[0].list.tight);
}

test "ordered list" {
    var p = init();
    var doc = try p.parseMarkdown(tst.allocator, "1. first\n2. second\n");
    defer doc.deinit(tst.allocator);
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
    var p = init();
    var doc = try p.parseMarkdown(tst.allocator, "\\*not emphasis\\*\n");
    defer doc.deinit(tst.allocator);
    try tst.expect(doc.children.items.len == 1);
    try tst.expect(doc.children.items[0] == .paragraph);
}

test "code span" {
    var p = init();
    var doc = try p.parseMarkdown(tst.allocator, "Use `code` here\n");
    defer doc.deinit(tst.allocator);
    const para = doc.children.items[0].paragraph;
    var found_code = false;
    for (para.children.items) |item| if (item == .code_span) {
        found_code = true;
    };
    try tst.expect(found_code);
}

test "autolink" {
    var p = init();
    var doc = try p.parseMarkdown(tst.allocator, "<https://example.com>\n");
    defer doc.deinit(tst.allocator);
    const para = doc.children.items[0].paragraph;
    try tst.expect(para.children.items[0] == .autolink);
    try tst.expect(!para.children.items[0].autolink.is_email);
}

test "image" {
    try ok("![alt](image.png)\n");
    var p = init();
    var doc = try p.parseMarkdown(tst.allocator, "![alt text](img.png)\n");
    defer doc.deinit(tst.allocator);
    const para = doc.children.items[0].paragraph;
    try tst.expect(para.children.items[0] == .image);
    try tst.expectEqualStrings("alt text", para.children.items[0].image.alt_text);
}

test {
    tst.refAllDecls(@This());
}
