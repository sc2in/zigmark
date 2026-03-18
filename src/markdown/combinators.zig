//! Mecha parser combinators and convenience `try*` wrappers used by the block parser.
//! Advanced callers may use the raw mecha parsers directly; most code should prefer
//! `parseMarkdown` via the main parser module.
const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;

const mecha = @import("mecha");

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
        // We count up to 3 spaces. If we have exactly 3, that's ok.
        // We need to also check line had 4+ spaces:
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

// ── Private helpers ───────────────────────────────────────────────────

fn trimLine(line: []const u8) []const u8 {
    return mem.trim(u8, line, " \t\r");
}
