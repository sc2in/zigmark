//! Inline Markdown parser — link reference definitions, emphasis, code spans,
//! autolinks, HTML tags, and reference links.
const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const unicode = std.unicode;

const AST = @import("ast.zig");

// ── Exported types ────────────────────────────────────────────────────────────

pub const RefMap = std.StringHashMap(struct { url: []const u8, title: ?[]const u8 });

// ── ASCII punctuation table ───────────────────────────────────────────────────

// Comptime truth-table: O(1) ASCII punctuation test — single array load,
// no branch chain.  Encodes the same set as the original four-range check.
const ascii_punct_table: [256]bool = blk: {
    var t = [_]bool{false} ** 256;
    var c: u9 = '!';
    while (c <= '/') : (c += 1) t[c] = true; // ! " # $ % & ' ( ) * + , - . /
    c = ':';
    while (c <= '@') : (c += 1) t[c] = true; // : ; < = > ? @
    c = '[';
    while (c <= '`') : (c += 1) t[c] = true; // [ \ ] ^ _ `
    c = '{';
    while (c <= '~') : (c += 1) t[c] = true; // { | } ~
    break :blk t;
};

fn isAsciiPunct(c: u8) bool {
    return ascii_punct_table[c];
}

// Break-char tables for the inline plain-text scan.  One array load replaces
// 9-10 comparisons per character in the hottest loop in the parser.
const inline_break_cm: [256]bool = blk: {
    var t = [_]bool{false} ** 256;
    for ("*_~[!`<\\\n") |c| t[c] = true;
    break :blk t;
};
const inline_break_gfm: [256]bool = blk: {
    var t = inline_break_cm;
    t['@'] = true;
    break :blk t;
};

// ── Link reference definitions ────────────────────────────────────────────────

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
pub fn tryConsumeLinkRefDef(
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

// 8KB comptime bitset covering the entire BMP (U+0000..U+FFFF).
// Bit N of byte bmp_punct_bitset[N/8] is set iff codepoint N is punctuation.
// This replaces a 70-iteration linear scan with a single bit-test for BMP chars.
// Supplementary-plane codepoints fall through to the linear scan (rare in practice).
const bmp_punct_bitset: [8192]u8 = blk: {
    // The bitset iterates over every BMP codepoint in each unicode range.
    // Total iterations are ~10 000 — raise the quota from the default of 1000.
    @setEvalBranchQuota(200_000);
    var bs = [_]u8{0} ** 8192;
    const UR = @import("unicode_ranges.zig");
    for (UR.ranges) |r| {
        if (r[0] > 0xFFFF) continue; // supplementary-only range
        const hi = if (r[1] > 0xFFFF) @as(u32, 0xFFFF) else r[1];
        var cp: u32 = r[0];
        while (cp <= hi) : (cp += 1) bs[cp / 8] |= @as(u8, 1) << @intCast(cp % 8);
    }
    break :blk bs;
};

fn isUnicodeCodepointPunct(cp: u32) bool {
    if (cp < 0x10000) {
        // Fast path: single bit-test in the 8KB BMP table (stays hot in L1 cache).
        return (bmp_punct_bitset[cp / 8] >> @intCast(cp % 8)) & 1 != 0;
    }
    // Supplementary planes (U+10000+): linear scan through only the supra-BMP ranges.
    const UR = @import("unicode_ranges.zig");
    for (UR.ranges) |r| {
        if (r[0] <= 0xFFFF) continue;
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
    if (marker == '*' or marker == '~') return lf;
    return lf and (!isRightFlanking(input, rs, rl) or (rs > 0 and isUnicodePunct(input, rs - 1)));
}

fn canClose(input: []const u8, marker: u8, rs: usize, rl: usize) bool {
    const rf = isRightFlanking(input, rs, rl);
    if (marker == '*' or marker == '~') return rf;
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
    const child_count = close_il -| (open_il + 1);
    if (child_count > 0) try children.ensureTotalCapacity(allocator, child_count);
    var ci = open_il + 1;
    while (ci < close_il) : (ci += 1) try children.append(allocator, inlines.items[ci]);

    const node: AST.Inline = if (closer.marker == '~')
        .{ .strikethrough = .{ .children = children } }
    else if (use_count == 2)
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

            // Strikethrough (~) requires at least 2 on each side
            if (closer.marker == '~' and (closer.count < 2 or opener.count < 2)) continue;
            found = true;
            const uc: usize = if (closer.marker == '~') 2 else if (closer.count >= 2 and opener.count >= 2) 2 else 1;
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

/// SIMD-accelerated scan for the first "break" character in inline text.
/// Uses @Vector comparisons (PCMPEQB/VPCMPEQB) to process `vlen` bytes per
/// iteration — up to 32x throughput vs scalar for long plain-text spans.
fn indexOfBreakChar(input: []const u8, pos: usize, gfm: bool) usize {
    const vlen = std.simd.suggestVectorLength(u8) orelse 1;
    const Vec = @Vector(vlen, u8);
    // Comptime-splat each needle — each becomes a PCMPEQB operand.
    const s_star: Vec = @splat('*');
    const s_under: Vec = @splat('_');
    const s_tilde: Vec = @splat('~');
    const s_lbrack: Vec = @splat('[');
    const s_bang: Vec = @splat('!');
    const s_btick: Vec = @splat('`');
    const s_lt: Vec = @splat('<');
    const s_bslash: Vec = @splat('\\');
    const s_nl: Vec = @splat('\n');
    const fallback = if (gfm) &inline_break_gfm else &inline_break_cm;
    var i = pos;
    while (i + vlen <= input.len) {
        const blk: Vec = input[i..][0..vlen].*;
        var hits = (blk == s_star) | (blk == s_under) | (blk == s_tilde) |
            (blk == s_lbrack) | (blk == s_bang) | (blk == s_btick) |
            (blk == s_lt) | (blk == s_bslash) | (blk == s_nl);
        if (gfm) hits = hits | (blk == @as(Vec, @splat('@')));
        if (@reduce(.Or, hits)) return i + std.simd.firstTrue(hits).?;
        i += vlen;
    }
    // Scalar tail for bytes that don't fill a full vector.
    while (i < input.len) : (i += 1) if (fallback[input[i]]) return i;
    return input.len;
}

pub fn parseInlineElements(allocator: Allocator, input: []const u8, ref_map: ?*const RefMap, gfm: bool) !std.ArrayList(AST.Inline) {
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
                const alt = try flattenInlineText(allocator, r.text, ref_map, gfm);
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
                if (tryParseImageRefLink(allocator, input, pos, rm, gfm)) |r| {
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
                var nested = try parseInlineElements(allocator, r.text, ref_map, gfm);
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
                if (tryParseRefLink(allocator, input, pos, rm, gfm)) |r| {
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

        // Strikethrough delimiter (GFM: ~~text~~)
        if (c == '~') {
            const rs = pos;
            var rl: usize = 0;
            while (pos + rl < input.len and input[pos + rl] == '~') rl += 1;
            if (rl >= 2) {
                const opens = canOpen(input, '~', rs, rl);
                const closes = canClose(input, '~', rs, rl);
                try inlines.append(allocator, .{ .text = .{ .content = input[rs .. rs + rl] } });
                if (opens or closes)
                    try delimiters.append(allocator, .{
                        .inline_idx = inlines.items.len - 1,
                        .input_pos = rs,
                        .count = rl,
                        .orig_count = rl,
                        .marker = '~',
                        .can_open = opens,
                        .can_close = closes,
                        .active = true,
                    });
            } else {
                try inlines.append(allocator, .{ .text = .{ .content = input[rs .. rs + rl] } });
            }
            pos += rl;
            continue;
        }

        // GFM email autolink — detect '@' using raw input for full local-part
        if (gfm and c == '@') {
            var local_start = pos;
            while (local_start > 0 and isEmailLocalChar(input[local_start - 1])) local_start -= 1;
            // Don't fire if local-part starts right after a backslash escape
            // (e.g. `<foo\+@bar.com>` — the `+` came from `\+`, not a bare local-part).
            const preceded_by_backslash = local_start > 0 and input[local_start - 1] == '\\';
            if (local_start < pos and !preceded_by_backslash) {
                // Scan forward for domain
                var domain_end = pos + 1;
                while (domain_end < input.len and isEmailDomainChar(input[domain_end])) domain_end += 1;
                // Trim trailing dots
                while (domain_end > pos + 1 and input[domain_end - 1] == '.') domain_end -= 1;
                const domain = input[pos + 1 .. domain_end];
                var has_period = false;
                for (domain) |ch| if (ch == '.') { has_period = true; break; };
                const last_ok = domain.len > 0 and domain[domain.len - 1] != '-' and domain[domain.len - 1] != '_';
                if (has_period and last_ok) {
                    // Strip already-emitted local-part chars from inlines/delimiters
                    stripLastNCharsFromInlines(&inlines, &delimiters, pos - local_start);
                    try inlines.append(allocator, .{ .autolink = .{
                        .url = input[local_start..domain_end],
                        .is_email = true,
                    } });
                    pos = domain_end;
                    continue;
                }
            }
            try inlines.append(allocator, .{ .text = .{ .content = input[pos .. pos + 1] } });
            pos += 1;
            continue;
        }

        // Plain text — SIMD scan; processes vlen bytes per iteration.
        const te = indexOfBreakChar(input, pos, gfm);
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

    if (gfm) try expandGfmAutolinks(allocator, &inlines);
    try processEmphasis(allocator, &inlines, &delimiters);
    return inlines;
}

// ── GFM Extended Autolinks ────────────────────────────────────────────────────

const GfmAutolinkMatch = struct {
    text_start: usize,
    text_end: usize,
    is_www: bool,
    is_email: bool,
};

fn isGfmUrlChar(c: u8) bool {
    return c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != '<';
}

fn isGfmWordBoundary(text: []const u8, i: usize) bool {
    if (i == 0) return true;
    const prev = text[i - 1];
    return !((prev >= 'a' and prev <= 'z') or (prev >= 'A' and prev <= 'Z') or
        (prev >= '0' and prev <= '9') or prev == '_');
}

/// Strip GFM trailing punctuation from a URL slice.
/// Returns the trimmed slice (a sub-slice of `url`).
fn trimGfmTrailingPunct(url: []const u8) []const u8 {
    var end = url.len;
    var changed = true;
    while (changed and end > 0) {
        changed = false;
        // Strip trailing single punctuation
        while (end > 0) {
            const last = url[end - 1];
            if (last == '.' or last == ',' or last == ':' or last == '!' or
                last == '?' or last == '_' or last == '*' or last == '~')
            {
                end -= 1;
                changed = true;
            } else break;
        }
        // Strip trailing entity ref (&name;)
        if (end > 0 and url[end - 1] == ';') {
            var j = end - 1;
            while (j > 0) {
                j -= 1;
                const ch = url[j];
                if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9')) continue;
                if (ch == '&' and j + 2 < end) {
                    end = j;
                    changed = true;
                }
                break;
            }
        }
        // Strip trailing unbalanced ')'
        if (end > 0 and url[end - 1] == ')') {
            var opens: usize = 0;
            var closes: usize = 0;
            for (url[0..end]) |ch| {
                if (ch == '(') opens += 1 else if (ch == ')') closes += 1;
            }
            if (closes > opens) {
                end -= closes - opens;
                changed = true;
            }
        }
    }
    return url[0..end];
}

fn gfmWwwLinkEnd(text: []const u8, after_www: usize) ?usize {
    // Collect non-space, non-< chars
    var end = after_www;
    while (end < text.len and isGfmUrlChar(text[end])) end += 1;
    if (end == after_www) return null;
    const raw_url = text[after_www - 4 .. end]; // full "www...."
    const trimmed = trimGfmTrailingPunct(raw_url);
    // Domain (before first / ? # or end) must contain at least one period after "www."
    const domain_part = trimmed[4..]; // after "www."
    var has_period = false;
    for (domain_part) |ch| {
        if (ch == '.' and ch != domain_part[0]) { has_period = true; break; }
        if (ch == '/' or ch == '?' or ch == '#') break;
        if (ch == '.') has_period = true;
    }
    // Simpler: check if there's any '.' in domain_part
    for (domain_part) |ch| {
        if (ch == '.') { has_period = true; break; }
        if (ch == '/' or ch == '?' or ch == '#') break;
    }
    if (!has_period) return null;
    return (after_www - 4) + trimmed.len;
}

fn gfmProtocolLinkEnd(text: []const u8, start: usize, proto_start: usize) ?usize {
    // start = position after "http://" etc., proto_start = position of "http"
    var end = start;
    while (end < text.len and isGfmUrlChar(text[end])) end += 1;
    if (end == start) return null;
    const raw_url = text[proto_start..end];
    const trimmed = trimGfmTrailingPunct(raw_url);
    if (trimmed.len == 0) return null;
    return proto_start + trimmed.len;
}

fn isEmailLocalChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or
        c == '.' or c == '!' or c == '#' or c == '$' or c == '%' or c == '&' or
        c == '\'' or c == '*' or c == '+' or c == '/' or c == '=' or c == '?' or
        c == '^' or c == '_' or c == '`' or c == '{' or c == '|' or c == '}' or
        c == '~' or c == '-';
}

fn isEmailDomainChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.';
}

fn gfmEmailMatch(text: []const u8, at_pos: usize) ?struct { start: usize, end: usize } {
    if (at_pos == 0) return null;
    // Scan backward for local-part
    var local_start = at_pos;
    while (local_start > 0 and isEmailLocalChar(text[local_start - 1])) local_start -= 1;
    if (local_start == at_pos) return null; // no local-part chars

    // Scan forward for domain: chars are [a-zA-Z0-9_-.], at least one period required
    var domain_end = at_pos + 1;
    while (domain_end < text.len and isEmailDomainChar(text[domain_end])) domain_end += 1;
    if (domain_end == at_pos + 1) return null; // no domain chars

    // Trim trailing '.' from domain
    while (domain_end > at_pos + 1 and text[domain_end - 1] == '.') domain_end -= 1;

    const domain = text[at_pos + 1 .. domain_end];
    if (domain.len == 0) return null;

    // Domain must have at least one period
    var has_period = false;
    for (domain) |ch| if (ch == '.') { has_period = true; break; };
    if (!has_period) return null;

    // Domain last char must not be '-' or '_'
    const last_domain_char = domain[domain.len - 1];
    if (last_domain_char == '-' or last_domain_char == '_') return null;

    return .{ .start = local_start, .end = domain_end };
}

fn findFirstGfmAutolink(text: []const u8) ?GfmAutolinkMatch {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        // www. link
        if (c == 'w' and i + 4 <= text.len and mem.eql(u8, text[i .. i + 4], "www.")) {
            if (isGfmWordBoundary(text, i)) {
                if (gfmWwwLinkEnd(text, i + 4)) |end| {
                    return .{ .text_start = i, .text_end = end, .is_www = true, .is_email = false };
                }
            }
        }

        // http:// or https:// or ftp://
        if (c == 'h' or c == 'f') {
            if (isGfmWordBoundary(text, i)) {
                const proto_len: ?usize = blk: {
                    if (i + 7 <= text.len and mem.eql(u8, text[i .. i + 7], "http://")) break :blk 7;
                    if (i + 8 <= text.len and mem.eql(u8, text[i .. i + 8], "https://")) break :blk 8;
                    if (i + 6 <= text.len and mem.eql(u8, text[i .. i + 6], "ftp://")) break :blk 6;
                    break :blk null;
                };
                if (proto_len) |pl| {
                    if (gfmProtocolLinkEnd(text, i + pl, i)) |end| {
                        return .{ .text_start = i, .text_end = end, .is_www = false, .is_email = false };
                    }
                }
            }
        }

        i += 1;
    }
    return null;
}

/// Remove the last `n` characters worth of content from the tail of `inlines`,
/// also removing any `delimiters` entries that point into the removed content.
fn stripLastNCharsFromInlines(
    inlines: *std.ArrayList(AST.Inline),
    delimiters: *std.ArrayList(Delimiter),
    n: usize,
) void {
    var remaining = n;
    while (remaining > 0 and inlines.items.len > 0) {
        const last = &inlines.items[inlines.items.len - 1];
        switch (last.*) {
            .text => |*t| {
                if (t.content.len <= remaining) {
                    remaining -= t.content.len;
                    // Remove any delimiter pointing at this inline
                    const idx = inlines.items.len - 1;
                    var di = delimiters.items.len;
                    while (di > 0) {
                        di -= 1;
                        if (delimiters.items[di].inline_idx == idx) {
                            _ = delimiters.orderedRemove(di);
                        }
                    }
                    inlines.items.len -= 1;
                } else {
                    t.content = t.content[0 .. t.content.len - remaining];
                    remaining = 0;
                }
            },
            else => break, // don't strip non-text nodes
        }
    }
}

fn expandGfmAutolinks(allocator: Allocator, inlines: *std.ArrayList(AST.Inline)) !void {
    var new_inlines = std.ArrayList(AST.Inline){};
    for (inlines.items) |item| {
        if (item == .text) {
            // Don't expand autolinks in text immediately following a literal '<'.
            // This prevents GFM expansion inside failed angle-bracket constructs
            // like `<https://foo.bar/baz bim>` or `< https://foo.bar >`.
            if (new_inlines.items.len > 0) {
                const prev = new_inlines.items[new_inlines.items.len - 1];
                if (prev == .text) {
                    const pc = prev.text.content;
                    if (pc.len > 0 and pc[pc.len - 1] == '<') {
                        try new_inlines.append(allocator, item);
                        continue;
                    }
                }
            }
            var remaining = item.text.content;
            while (remaining.len > 0) {
                if (findFirstGfmAutolink(remaining)) |m| {
                    if (m.text_start > 0)
                        try new_inlines.append(allocator, .{ .text = .{ .content = remaining[0..m.text_start] } });
                    try new_inlines.append(allocator, .{ .autolink = .{
                        .url = remaining[m.text_start..m.text_end],
                        .is_email = m.is_email,
                        .is_gfm_www = m.is_www,
                    } });
                    remaining = remaining[m.text_end..];
                } else {
                    try new_inlines.append(allocator, .{ .text = .{ .content = remaining } });
                    break;
                }
            }
        } else {
            try new_inlines.append(allocator, item);
        }
    }
    inlines.deinit(allocator);
    inlines.* = new_inlines;
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

fn flattenInlineText(allocator: Allocator, input: []const u8, ref_map: ?*const RefMap, gfm: bool) Allocator.Error![]const u8 {
    var inlines = try parseInlineElements(allocator, input, ref_map, gfm);
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
        .strikethrough => |s| {
            for (s.children.items) |child| try flattenInline(allocator, buf, child);
        },
        .hard_break, .autolink, .footnote_reference, .html_in_line => {},
    }
}

pub fn tryParseHtmlTag(input: []const u8, pos: usize) ?usize {
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

fn tryParseImageRefLink(allocator: Allocator, input: []const u8, start: usize, rm: *const RefMap, gfm: bool) ?InlineParseResult {
    if (start >= input.len or input[start] != '!' or start + 1 >= input.len or input[start + 1] != '[') return null;
    const be = findClosingBracket(input, start + 2) orelse return null;
    const raw_alt = input[start + 2 .. be];

    // Full reference: ![alt][label]
    if (be + 1 < input.len and input[be + 1] == '[') {
        // Collapsed: ![alt][]
        if (be + 2 < input.len and input[be + 2] == ']') {
            if (resolveRef(allocator, rm, raw_alt)) |ref| {
                const flat = flattenInlineText(allocator, raw_alt, rm, gfm) catch return null;
                return .{ .inline_node = .{ .image = .{ .alt_text = flat, .destination = .{ .url = ref.url, .title = ref.title }, .link_type = .collapsed } }, .end = be + 3 };
            }
        } else {
            var le: usize = be + 2;
            while (le < input.len and input[le] != ']') le += 1;
            if (le < input.len) {
                if (resolveRef(allocator, rm, input[be + 2 .. le])) |ref| {
                    const flat = flattenInlineText(allocator, raw_alt, rm, gfm) catch return null;
                    return .{ .inline_node = .{ .image = .{ .alt_text = flat, .destination = .{ .url = ref.url, .title = ref.title }, .link_type = .reference } }, .end = le + 1 };
                }
            }
        }
    }
    // Shortcut: ![alt]
    if (resolveRef(allocator, rm, raw_alt)) |ref| {
        const flat = flattenInlineText(allocator, raw_alt, rm, gfm) catch return null;
        return .{ .inline_node = .{ .image = .{ .alt_text = flat, .destination = .{ .url = ref.url, .title = ref.title }, .link_type = .shortcut } }, .end = be + 1 };
    }
    return null;
}

fn tryParseRefLink(allocator: Allocator, input: []const u8, start: usize, rm: *const RefMap, gfm: bool) ?InlineParseResult {
    if (start >= input.len or input[start] != '[') return null;
    const be = findClosingBracket(input, start + 1) orelse return null;
    const link_text = input[start + 1 .. be];
    var tried_full = false;

    if (be + 1 < input.len and input[be + 1] == '[') {
        tried_full = true;
        // Collapsed: [text][]
        if (be + 2 < input.len and input[be + 2] == ']') {
            if (resolveRef(allocator, rm, link_text)) |ref|
                return buildRefLink(allocator, link_text, ref, .collapsed, be + 3, rm, gfm);
        } else {
            // Full: [text][label]
            var le: usize = be + 2;
            while (le < input.len and input[le] != ']') le += 1;
            if (le < input.len) {
                if (resolveRef(allocator, rm, input[be + 2 .. le])) |ref|
                    return buildRefLink(allocator, link_text, ref, .reference, le + 1, rm, gfm);
            }
        }
    }
    // Shortcut: [text]
    if (!tried_full) {
        if (resolveRef(allocator, rm, link_text)) |ref|
            return buildRefLink(allocator, link_text, ref, .shortcut, be + 1, rm, gfm);
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
    gfm: bool,
) ?InlineParseResult {
    var link = AST.Link.init(allocator, .{ .url = ref.url, .title = ref.title }, link_type);
    var nested = parseInlineElements(allocator, text, rm, gfm) catch return null;
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

// ── Private helpers ───────────────────────────────────────────────────────────

fn trimLine(line: []const u8) []const u8 {
    return mem.trim(u8, line, " \t\r");
}
