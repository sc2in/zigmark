//! HTML renderer for the Markdown AST — CommonMark + GFM.
//!
//! Serialises an `AST.Document` into CommonMark-compliant HTML.  The
//! output follows the same conventions as the CommonMark reference
//! implementation (`cmark`): UTF-8, self-closing tags for void elements
//! (e.g. `<br />`, `<hr />`), and minimal attribute quoting.
//!
//! GFM extensions rendered:
//!   - Tables → `<table>`/`<thead>`/`<tbody>`/`<tr>`/`<th>`/`<td>` with `align` attributes
//!   - Task list items → `<input disabled="" type="checkbox">` inside `<li>`
//!   - Strikethrough → `<del>…</del>`
//!   - Extended autolinks → `<a href="…">` (www links get an `http://` href prefix)
//!   - Disallowed raw HTML → `<` of dangerous tags escaped to `&lt;`
const std = @import("std");
const Allocator = std.mem.Allocator;
const tst = std.testing;

const AST = @import("../ast.zig");
const Parser = @import("../parser.zig");

// ── HTML-escape helper ────────────────────────────────────────────────────────

fn writeEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(c),
        }
    }
}

/// Write text with HTML entity decoding and HTML escaping.
/// Recognized entities are decoded to UTF-8, then the result is HTML-escaped.
/// Unrecognized entities pass through as `&amp;name;`.
fn writeEscapedWithEntities(writer: anytype, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '&') {
            if (tryDecodeEntity(s, i)) |ent| {
                // Write decoded bytes with HTML escaping
                var j: u4 = 0;
                while (j < ent.len) : (j += 1) {
                    const b = ent.bytes[j];
                    switch (b) {
                        '&' => try writer.writeAll("&amp;"),
                        '<' => try writer.writeAll("&lt;"),
                        '>' => try writer.writeAll("&gt;"),
                        '"' => try writer.writeAll("&quot;"),
                        else => try writer.writeByte(b),
                    }
                }
                i += ent.consumed;
                continue;
            }
            try writer.writeAll("&amp;");
            i += 1;
            continue;
        }
        switch (c) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(c),
        }
        i += 1;
    }
}

/// Write a URL with HTML-escaping AND percent-encoding for characters that
/// need it (spaces, non-ASCII, etc.), while preserving already-encoded %XX sequences.
fn writeUrlEncoded(writer: anytype, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '&') {
            try writer.writeAll("&amp;");
        } else if (c == '"') {
            try writer.writeAll("%22");
        } else if (c == '\'') {
            try writer.writeAll("%27");
        } else if (c == ' ') {
            try writer.writeAll("%20");
        } else if (c == '[') {
            try writer.writeAll("%5B");
        } else if (c == ']') {
            try writer.writeAll("%5D");
        } else if (c == '\\') {
            // Backslash escape in URL context: if followed by ASCII punct, consume the
            // backslash and encode the punctuation char; otherwise encode the backslash.
            if (i + 1 < s.len and isAsciiPunctuation(s[i + 1])) {
                // Output the escaped character directly (it's the literal char)
                try writer.writeByte(s[i + 1]);
                i += 2;
                continue;
            } else {
                try writer.writeAll("%5C");
            }
        } else if (c == '%' and i + 2 < s.len and isHexDigit(s[i + 1]) and isHexDigit(s[i + 2])) {
            // Already percent-encoded — pass through
            try writer.writeByte('%');
            try writer.writeByte(s[i + 1]);
            try writer.writeByte(s[i + 2]);
            i += 3;
            continue;
        } else if (c >= 0x80) {
            // Non-ASCII: percent-encode each byte
            try writer.print("%{X:0>2}", .{c});
        } else {
            try writer.writeByte(c);
        }
        i += 1;
    }
}

/// Comptime-generated lookup table for ASCII punctuation characters.
/// Branchless O(1) check instead of 4 range comparisons.
const ascii_punct_table = blk: {
    var table = [_]bool{false} ** 128;
    for (0..128) |i| {
        const c: u8 = @intCast(i);
        table[i] = (c >= '!' and c <= '/') or (c >= ':' and c <= '@') or
            (c >= '[' and c <= '`') or (c >= '{' and c <= '~');
    }
    break :blk table;
};

fn isAsciiPunctuation(c: u8) bool {
    return c < 128 and ascii_punct_table[c];
}

/// Write a URL literally (no backslash escape processing), with percent-encoding
/// for characters that need it. Used for autolinks where backslash is NOT an
/// escape character.
fn writeUrlEncodedLiteral(writer: anytype, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '&') {
            try writer.writeAll("&amp;");
        } else if (c == '"') {
            try writer.writeAll("%22");
        } else if (c == '\'') {
            try writer.writeAll("%27");
        } else if (c == ' ') {
            try writer.writeAll("%20");
        } else if (c == '[') {
            try writer.writeAll("%5B");
        } else if (c == ']') {
            try writer.writeAll("%5D");
        } else if (c == '\\') {
            try writer.writeAll("%5C");
        } else if (c == '`') {
            try writer.writeAll("%60");
        } else if (c == '%' and i + 2 < s.len and isHexDigit(s[i + 1]) and isHexDigit(s[i + 2])) {
            try writer.writeByte('%');
            try writer.writeByte(s[i + 1]);
            try writer.writeByte(s[i + 2]);
            i += 3;
            continue;
        } else if (c >= 0x80) {
            try writer.print("%{X:0>2}", .{c});
        } else {
            try writer.writeByte(c);
        }
        i += 1;
    }
}

/// Write text with backslash escape processing + HTML escaping.
/// Backslash-escaped ASCII punctuation chars have the backslash removed.
fn writeEscapedWithBackslash(writer: anytype, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and isAsciiPunctuation(s[i + 1])) {
            // Write the escaped character with HTML escaping
            switch (s[i + 1]) {
                '&' => try writer.writeAll("&amp;"),
                '<' => try writer.writeAll("&lt;"),
                '>' => try writer.writeAll("&gt;"),
                '"' => try writer.writeAll("&quot;"),
                else => try writer.writeByte(s[i + 1]),
            }
            i += 2;
        } else {
            switch (c) {
                '&' => try writer.writeAll("&amp;"),
                '<' => try writer.writeAll("&lt;"),
                '>' => try writer.writeAll("&gt;"),
                '"' => try writer.writeAll("&quot;"),
                else => try writer.writeByte(c),
            }
            i += 1;
        }
    }
}

/// Comptime-generated lookup table for hex digit detection.
const hex_digit_table = blk: {
    var table = [_]bool{false} ** 128;
    for ('0'..'9' + 1) |i| table[i] = true;
    for ('a'..'f' + 1) |i| table[i] = true;
    for ('A'..'F' + 1) |i| table[i] = true;
    break :blk table;
};

fn isHexDigit(c: u8) bool {
    return c < 128 and hex_digit_table[c];
}

fn hexDigitVal(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 0;
}

/// Encode a Unicode codepoint as UTF-8 into a buffer. Returns the number of bytes written.
fn encodeUtf8Buf(cp: u21, buf: *[4]u8) u3 {
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

/// Result of decoding an HTML entity: UTF-8 bytes and their length.
const EntityResult = struct { bytes: [8]u8, len: u4 };

/// Resolve a named HTML entity to its UTF-8 byte sequence.
/// Returns the bytes and length, or null if the entity is not recognized.
/// Supports multi-codepoint entities (e.g. &ngE; → U+2267 U+0338).
///
/// Uses a comptime-generated `StaticStringMap` for O(1) average-case lookup
/// instead of a linear scan through the entity table.
fn resolveNamedEntity(name: []const u8) ?EntityResult {
    const bytes = entity_map.get(name) orelse return null;
    var result: EntityResult = .{ .bytes = undefined, .len = @intCast(bytes.len) };
    @memcpy(result.bytes[0..bytes.len], bytes);
    return result;
}

/// Comptime-generated perfect hash map from entity name → UTF-8 bytes.
const entity_map = std.StaticStringMap([]const u8).initComptime(blk: {
    var kvs: [EntryMap.len]struct { []const u8, []const u8 } = undefined;
    for (EntryMap, 0..) |entry, i| {
        kvs[i] = .{ entry.name, entry.bytes };
    }
    break :blk &kvs;
});

/// Try to parse an HTML entity reference at position `i` in `s`.
/// Returns the entity's UTF-8 bytes and the number of source bytes consumed, or null if not an entity.
/// Supports multi-codepoint named entities (up to 8 bytes of UTF-8).
const DecodedEntity = struct { bytes: [8]u8, len: u4, consumed: usize };
fn tryDecodeEntity(s: []const u8, i: usize) ?DecodedEntity {
    if (i >= s.len or s[i] != '&') return null;
    if (i + 1 >= s.len) return null;

    // Numeric character reference
    if (s[i + 1] == '#') {
        if (i + 2 >= s.len) return null;
        var cp: u32 = 0;
        var pos = i + 2;
        if (s[pos] == 'x' or s[pos] == 'X') {
            // Hex: &#xHHHH; — 1-6 hex digits per CommonMark spec
            pos += 1;
            const start = pos;
            while (pos < s.len and isHexDigit(s[pos]) and pos - start < 6) : (pos += 1) {
                cp = cp * 16 + hexDigitVal(s[pos]);
            }
            if (pos == start or pos >= s.len or s[pos] != ';') return null;
            // If there are more hex digits, it's not a valid reference
            if (pos < s.len and isHexDigit(s[pos])) return null;
        } else {
            // Decimal: &#DDDD; — 1-7 digits per CommonMark spec
            const start = pos;
            while (pos < s.len and s[pos] >= '0' and s[pos] <= '9' and pos - start < 7) : (pos += 1) {
                cp = cp * 10 + (s[pos] - '0');
            }
            if (pos == start or pos >= s.len or s[pos] != ';') return null;
            // If there are more digits, it's not a valid reference
            if (pos < s.len and s[pos] >= '0' and s[pos] <= '9') return null;
        }
        if (cp == 0 or cp > 0x10FFFF) cp = 0xFFFD;
        var buf: [8]u8 = undefined;
        const len = encodeUtf8Buf(@intCast(cp), buf[0..4]);
        return .{ .bytes = buf, .len = len, .consumed = pos + 1 - i };
    }

    // Named entity reference: &name;
    const name_start = i + 1;
    var pos = name_start;
    while (pos < s.len and pos - name_start < 32 and
        ((s[pos] >= 'a' and s[pos] <= 'z') or (s[pos] >= 'A' and s[pos] <= 'Z') or
            (s[pos] >= '0' and s[pos] <= '9'))) : (pos += 1)
    {}
    if (pos == name_start or pos >= s.len or s[pos] != ';') return null;
    const name = s[name_start..pos];
    if (resolveNamedEntity(name)) |ent| {
        var buf: [8]u8 = undefined;
        @memcpy(buf[0..ent.len], ent.bytes[0..ent.len]);
        return .{ .bytes = buf, .len = ent.len, .consumed = pos + 1 - i };
    }
    return null;
}

/// Write a URL with percent-encoding and HTML entity decoding.
/// HTML entities in the URL are first decoded to their UTF-8 representation,
/// then percent-encoded if needed.
fn writeUrlEncodedWithEntities(writer: anytype, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '&') {
            // Try to decode an HTML entity
            if (tryDecodeEntity(s, i)) |ent| {
                // Write the decoded bytes through percent-encoding
                var j: u4 = 0;
                while (j < ent.len) : (j += 1) {
                    const b = ent.bytes[j];
                    if (b >= 0x80) {
                        try writer.print("%{X:0>2}", .{b});
                    } else if (b == '"') {
                        try writer.writeAll("%22");
                    } else if (b == '\'') {
                        try writer.writeAll("%27");
                    } else if (b == ' ') {
                        try writer.writeAll("%20");
                    } else if (b == '&') {
                        try writer.writeAll("&amp;");
                    } else {
                        try writer.writeByte(b);
                    }
                }
                i += ent.consumed;
                continue;
            }
            try writer.writeAll("&amp;");
            i += 1;
            continue;
        }
        if (c == '"') {
            try writer.writeAll("%22");
        } else if (c == '\'') {
            try writer.writeAll("%27");
        } else if (c == ' ') {
            try writer.writeAll("%20");
        } else if (c == '\\') {
            if (i + 1 < s.len and isAsciiPunctuation(s[i + 1])) {
                try writer.writeByte(s[i + 1]);
                i += 2;
                continue;
            } else {
                try writer.writeAll("%5C");
            }
        } else if (c == '%' and i + 2 < s.len and isHexDigit(s[i + 1]) and isHexDigit(s[i + 2])) {
            try writer.writeByte('%');
            try writer.writeByte(s[i + 1]);
            try writer.writeByte(s[i + 2]);
            i += 3;
            continue;
        } else if (c >= 0x80) {
            try writer.print("%{X:0>2}", .{c});
        } else {
            try writer.writeByte(c);
        }
        i += 1;
    }
}

/// Write title text with HTML entity decoding, backslash escape processing, and HTML escaping.
fn writeEscapedTitleWithEntities(writer: anytype, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '&') {
            if (tryDecodeEntity(s, i)) |ent| {
                // Write decoded bytes with HTML escaping
                var j: u4 = 0;
                while (j < ent.len) : (j += 1) {
                    const b = ent.bytes[j];
                    switch (b) {
                        '&' => try writer.writeAll("&amp;"),
                        '<' => try writer.writeAll("&lt;"),
                        '>' => try writer.writeAll("&gt;"),
                        '"' => try writer.writeAll("&quot;"),
                        else => try writer.writeByte(b),
                    }
                }
                i += ent.consumed;
                continue;
            }
            try writer.writeAll("&amp;");
            i += 1;
            continue;
        }
        if (c == '\\' and i + 1 < s.len and isAsciiPunctuation(s[i + 1])) {
            switch (s[i + 1]) {
                '&' => try writer.writeAll("&amp;"),
                '<' => try writer.writeAll("&lt;"),
                '>' => try writer.writeAll("&gt;"),
                '"' => try writer.writeAll("&quot;"),
                else => try writer.writeByte(s[i + 1]),
            }
            i += 2;
            continue;
        }
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(c),
        }
        i += 1;
    }
}

// ── GFM disallowed raw HTML filter ───────────────────────────────────────────

/// GFM tagfilter: these tags must have their '<' escaped to '&lt;'
const disallowed_html_tags = std.StaticStringMap(void).initComptime(.{
    .{ "title", {} },    .{ "textarea", {} }, .{ "style", {} },
    .{ "xmp", {} },      .{ "iframe", {} },   .{ "noembed", {} },
    .{ "noframes", {} }, .{ "script", {} },   .{ "plaintext", {} },
});

fn writeHtmlFiltered(writer: anytype, s: []const u8, gfm: bool) !void {
    if (!gfm) return writer.writeAll(s);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '<' and i + 1 < s.len) {
            const rest = s[i + 1 ..];
            // Skip optional '/' for closing tags
            const tag_offset: usize = if (rest.len > 0 and rest[0] == '/') 1 else 0;
            // Extract tag name lowercased (max 16 chars)
            var tag_buf: [16]u8 = undefined;
            var tag_len: usize = 0;
            var k = tag_offset;
            while (k < rest.len and tag_len < 16) {
                const ch = rest[k];
                if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
                    tag_buf[tag_len] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
                    tag_len += 1;
                    k += 1;
                } else break;
            }
            // After tag name must be space, >, /, \t, \n, or end-of-string
            const after_tag = tag_offset + tag_len;
            const valid_end = after_tag >= rest.len or
                rest[after_tag] == ' ' or rest[after_tag] == '>' or
                rest[after_tag] == '/' or rest[after_tag] == '\t' or rest[after_tag] == '\n';
            if (tag_len > 0 and valid_end and disallowed_html_tags.has(tag_buf[0..tag_len])) {
                try writer.writeAll("&lt;");
            } else {
                try writer.writeByte('<');
            }
        } else {
            try writer.writeByte(s[i]);
        }
        i += 1;
    }
}

// ── Inline renderer ───────────────────────────────────────────────────────────

fn renderInline(writer: anytype, item: AST.Inline, gfm: bool) !void {
    switch (item) {
        .text => |t| try writeEscapedWithEntities(writer, t.content),
        .soft_break => try writer.writeByte('\n'),
        .hard_break => try writer.writeAll("<br />\n"),
        .code_span => |cs| {
            try writer.writeAll("<code>");
            try writeEscaped(writer, cs.content);
            try writer.writeAll("</code>");
        },
        .emphasis => |e| {
            try writer.writeAll("<em>");
            for (e.children.items) |child| try renderInline(writer, child, gfm);
            try writer.writeAll("</em>");
        },
        .strong => |s| {
            try writer.writeAll("<strong>");
            for (s.children.items) |child| try renderInline(writer, child, gfm);
            try writer.writeAll("</strong>");
        },
        .strikethrough => |s| {
            try writer.writeAll("<del>");
            for (s.children.items) |child| try renderInline(writer, child, gfm);
            try writer.writeAll("</del>");
        },
        .link => |l| {
            try writer.writeAll("<a href=\"");
            try writeUrlEncodedWithEntities(writer, l.destination.url);
            try writer.writeByte('"');
            if (l.destination.title) |title| {
                try writer.writeAll(" title=\"");
                try writeEscapedTitleWithEntities(writer, title);
                try writer.writeByte('"');
            }
            try writer.writeByte('>');
            for (l.children.items) |child| try renderInline(writer, child, gfm);
            try writer.writeAll("</a>");
        },
        .image => |img| {
            try writer.writeAll("<img src=\"");
            try writeUrlEncodedWithEntities(writer, img.destination.url);
            try writer.writeAll("\" alt=\"");
            try writeEscaped(writer, img.alt_text);
            try writer.writeByte('"');
            if (img.destination.title) |title| {
                try writer.writeAll(" title=\"");
                try writeEscapedTitleWithEntities(writer, title);
                try writer.writeByte('"');
            }
            try writer.writeAll(" />");
        },
        .autolink => |al| {
            try writer.writeAll("<a href=\"");
            if (al.is_email) try writer.writeAll("mailto:");
            if (al.is_gfm_www) try writer.writeAll("http://");
            try writeUrlEncodedLiteral(writer, al.url);
            try writer.writeAll("\">");
            try writeEscaped(writer, al.url);
            try writer.writeAll("</a>");
        },
        .footnote_reference => |fr| {
            try writer.print("<a href=\"#fn:{s}\" class=\"footnote-ref\">{s}</a>", .{ fr.label, fr.label });
        },
        .html_in_line => |hi| try writeHtmlFiltered(writer, hi.content, gfm),
    }
}

// ── Block renderer ────────────────────────────────────────────────────────────

const RenderCtx = struct {
    gfm: bool,
    allocator: Allocator,
    mermaid: ?*const fn (Allocator, []const u8) anyerror![]const u8 = null,
};

fn renderBlock(writer: *std.Io.Writer, block: AST.Block, ctx: *const RenderCtx) !void {
    switch (block) {
        .table => |tbl| {
            try writer.writeAll("<table>\n");

            // header
            try writer.writeAll("<thead>\n<tr>\n");
            for (tbl.header.cells.items, tbl.alignments.items) |cell, col_align| {
                switch (col_align) {
                    .none => try writer.writeAll("<th>"),
                    .left => try writer.writeAll("<th align=\"left\">"),
                    .center => try writer.writeAll("<th align=\"center\">"),
                    .right => try writer.writeAll("<th align=\"right\">"),
                }
                for (cell.children.items) |inl| try renderInline(writer, inl, ctx.gfm);
                try writer.writeAll("</th>\n");
            }
            try writer.writeAll("</tr>\n</thead>\n");

            // body
            if (tbl.body.items.len > 0) {
                try writer.writeAll("<tbody>\n");
                for (tbl.body.items) |row| {
                    try writer.writeAll("<tr>\n");
                    for (row.cells.items, tbl.alignments.items) |cell, col_align| {
                        switch (col_align) {
                            .none => try writer.writeAll("<td>"),
                            .left => try writer.writeAll("<td align=\"left\">"),
                            .center => try writer.writeAll("<td align=\"center\">"),
                            .right => try writer.writeAll("<td align=\"right\">"),
                        }
                        for (cell.children.items) |inl| try renderInline(writer, inl, ctx.gfm);
                        try writer.writeAll("</td>\n");
                    }
                    try writer.writeAll("</tr>\n");
                }
                try writer.writeAll("</tbody>\n");
            }

            try writer.writeAll("</table>\n");
        },

        .heading => |h| {
            try writer.print("<h{d}>", .{h.level});
            for (h.children.items) |item| try renderInline(writer, item, ctx.gfm);
            try writer.print("</h{d}>\n", .{h.level});
        },
        .paragraph => |p| {
            try writer.writeAll("<p>");
            for (p.children.items) |item| try renderInline(writer, item, ctx.gfm);
            try writer.writeAll("</p>\n");
        },
        .thematic_break => try writer.writeAll("<hr />\n"),
        .code_block => |cb| {
            try writer.writeAll("<pre><code>");
            try writeEscaped(writer, cb.content);
            try writer.writeAll("\n</code></pre>\n");
        },
        .fenced_code_block => |fcb| {
            mermaid: {
                if (ctx.mermaid) |mfn| {
                    const is_mermaid = if (fcb.language) |l| std.mem.eql(u8, l, "mermaid") or std.mem.eql(u8, l, "mermaidjs") else false;
                    if (!is_mermaid) break :mermaid;
                    const svg = mfn(ctx.allocator, fcb.content) catch break :mermaid;
                    defer ctx.allocator.free(svg);
                    try writer.writeAll("<figure class=\"mermaid-diagram\">\n");
                    try writer.writeAll(svg);
                    try writer.writeAll("</figure>\n");
                    return;
                }
            }
            if (fcb.language) |lang| {
                try writer.writeAll("<pre><code class=\"language-");
                try writeEscapedTitleWithEntities(writer, lang);
                try writer.writeAll("\">");
            } else {
                try writer.writeAll("<pre><code>");
            }
            if (fcb.content.len > 0) {
                try writeEscaped(writer, fcb.content);
                try writer.writeAll("\n");
            }
            try writer.writeAll("</code></pre>\n");
        },
        .blockquote => |bq| {
            try writer.writeAll("<blockquote>\n");
            for (bq.children.items) |child| try renderBlock(writer, child, ctx);
            try writer.writeAll("</blockquote>\n");
        },
        .list => |lst| {
            const tag: []const u8 = if (lst.type == .ordered) "ol" else "ul";
            if (lst.type == .ordered) {
                if (lst.start) |s| {
                    if (s != 1) {
                        try writer.print("<ol start=\"{d}\">\n", .{s});
                    } else {
                        try writer.writeAll("<ol>\n");
                    }
                } else {
                    try writer.writeAll("<ol>\n");
                }
            } else {
                try writer.writeAll("<ul>\n");
            }
            for (lst.items.items) |item| {
                if (lst.tight) {
                    // Check if the item starts with a paragraph
                    const starts_with_para = item.children.items.len > 0 and
                        item.children.items[0] == .paragraph;
                    if (starts_with_para) {
                        try writer.writeAll("<li>");
                        if (item.task_list_checked) |checked| {
                            if (checked) {
                                try writer.writeAll("<input checked=\"\" disabled=\"\" type=\"checkbox\"> ");
                            } else {
                                try writer.writeAll("<input disabled=\"\" type=\"checkbox\"> ");
                            }
                        }
                    } else {
                        // Item has only block-level children (e.g. code blocks)
                        if (item.children.items.len == 0) {
                            try writer.writeAll("<li>");
                        } else {
                            try writer.writeAll("<li>\n");
                        }
                    }
                    // Tight: render inline content only (no wrapping <p>)
                    var wrote_inline = false;
                    for (item.children.items) |child| {
                        switch (child) {
                            .paragraph => |p| {
                                for (p.children.items) |inl| try renderInline(writer, inl, ctx.gfm);
                                wrote_inline = true;
                            },
                            else => {
                                // Non-paragraph block: add newline separator
                                if (wrote_inline) {
                                    try writer.writeByte('\n');
                                }
                                wrote_inline = false;
                                try renderBlock(writer, child, ctx);
                            },
                        }
                    }
                    try writer.writeAll("</li>\n");
                } else {
                    // Loose: render with block structure
                    if (item.children.items.len == 0) {
                        try writer.writeAll("<li>");
                    } else {
                        try writer.writeAll("<li>\n");
                        for (item.children.items) |child| try renderBlock(writer, child, ctx);
                    }
                    try writer.writeAll("</li>\n");
                }
            }
            try writer.print("</{s}>\n", .{tag});
        },
        .footnote_definition => |fd| {
            try writer.print("<div class=\"footnote\" id=\"fn:{s}\">\n", .{fd.label});
            for (fd.children.items) |child| {
                switch (child) {
                    .paragraph => |p| {
                        try writer.print("<p><b>{s}</b>: ", .{fd.label});
                        for (p.children.items) |inl| try renderInline(writer, inl, ctx.gfm);
                        try writer.writeAll("</p>\n");
                    },
                    else => try renderBlock(writer, child, ctx),
                }
            }
            try writer.writeAll("</div>\n");
        },
        .html_block => |hb| try writeHtmlFiltered(writer, hb.content, ctx.gfm),
    }
}

// ── Top-level render ──────────────────────────────────────────────────────────

/// Render `doc` to a writer with CommonMark-compliant HTML.
pub fn renderToWriter(allocator: Allocator, writer: *std.Io.Writer, doc: AST.Document) !void {
    const ctx: RenderCtx = .{ .gfm = doc.gfm, .allocator = allocator };
    for (doc.children.items) |child| try renderBlock(writer, child, &ctx);
}

/// Render `doc` to a writer, converting mermaid fenced blocks to inline SVG
/// using the provided renderer function.
pub fn renderToWriterWithMermaid(
    allocator: Allocator,
    writer: *std.Io.Writer,
    doc: AST.Document,
    mermaid: ?*const fn (Allocator, []const u8) anyerror![]const u8,
) !void {
    const ctx: RenderCtx = .{ .gfm = doc.gfm, .allocator = allocator, .mermaid = mermaid };
    for (doc.children.items) |child| try renderBlock(writer, child, &ctx);
}

/// Render `doc` to an allocator-owned HTML byte slice.
///
/// The caller owns the returned memory and must free it when done.
pub fn render(allocator: Allocator, doc: AST.Document) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try renderToWriter(allocator, &aw.writer, doc);
    return aw.toOwnedSlice();
}

// - Misc
const Entry = struct { name: []const u8, bytes: []const u8 };

const EntryMap = [_]Entry{
    // XML predefined
    .{ .name = "amp", .bytes = "&" },
    .{ .name = "lt", .bytes = "<" },
    .{ .name = "gt", .bytes = ">" },
    .{ .name = "quot", .bytes = "\"" },
    .{ .name = "apos", .bytes = "'" },
    // Latin-1 supplement
    .{ .name = "nbsp", .bytes = "\xC2\xA0" },
    .{ .name = "iexcl", .bytes = "\xC2\xA1" },
    .{ .name = "cent", .bytes = "\xC2\xA2" },
    .{ .name = "pound", .bytes = "\xC2\xA3" },
    .{ .name = "curren", .bytes = "\xC2\xA4" },
    .{ .name = "yen", .bytes = "\xC2\xA5" },
    .{ .name = "brvbar", .bytes = "\xC2\xA6" },
    .{ .name = "sect", .bytes = "\xC2\xA7" },
    .{ .name = "uml", .bytes = "\xC2\xA8" },
    .{ .name = "copy", .bytes = "\xC2\xA9" },
    .{ .name = "ordf", .bytes = "\xC2\xAA" },
    .{ .name = "laquo", .bytes = "\xC2\xAB" },
    .{ .name = "not", .bytes = "\xC2\xAC" },
    .{ .name = "shy", .bytes = "\xC2\xAD" },
    .{ .name = "reg", .bytes = "\xC2\xAE" },
    .{ .name = "macr", .bytes = "\xC2\xAF" },
    .{ .name = "deg", .bytes = "\xC2\xB0" },
    .{ .name = "plusmn", .bytes = "\xC2\xB1" },
    .{ .name = "sup2", .bytes = "\xC2\xB2" },
    .{ .name = "sup3", .bytes = "\xC2\xB3" },
    .{ .name = "acute", .bytes = "\xC2\xB4" },
    .{ .name = "micro", .bytes = "\xC2\xB5" },
    .{ .name = "para", .bytes = "\xC2\xB6" },
    .{ .name = "middot", .bytes = "\xC2\xB7" },
    .{ .name = "cedil", .bytes = "\xC2\xB8" },
    .{ .name = "sup1", .bytes = "\xC2\xB9" },
    .{ .name = "ordm", .bytes = "\xC2\xBA" },
    .{ .name = "raquo", .bytes = "\xC2\xBB" },
    .{ .name = "frac14", .bytes = "\xC2\xBC" },
    .{ .name = "frac12", .bytes = "\xC2\xBD" },
    .{ .name = "frac34", .bytes = "\xC2\xBE" },
    .{ .name = "iquest", .bytes = "\xC2\xBF" },
    .{ .name = "Agrave", .bytes = "\xC3\x80" },
    .{ .name = "Aacute", .bytes = "\xC3\x81" },
    .{ .name = "Acirc", .bytes = "\xC3\x82" },
    .{ .name = "Atilde", .bytes = "\xC3\x83" },
    .{ .name = "Auml", .bytes = "\xC3\x84" },
    .{ .name = "Aring", .bytes = "\xC3\x85" },
    .{ .name = "AElig", .bytes = "\xC3\x86" },
    .{ .name = "Ccedil", .bytes = "\xC3\x87" },
    .{ .name = "Egrave", .bytes = "\xC3\x88" },
    .{ .name = "Eacute", .bytes = "\xC3\x89" },
    .{ .name = "Ecirc", .bytes = "\xC3\x8A" },
    .{ .name = "Euml", .bytes = "\xC3\x8B" },
    .{ .name = "Igrave", .bytes = "\xC3\x8C" },
    .{ .name = "Iacute", .bytes = "\xC3\x8D" },
    .{ .name = "Icirc", .bytes = "\xC3\x8E" },
    .{ .name = "Iuml", .bytes = "\xC3\x8F" },
    .{ .name = "ETH", .bytes = "\xC3\x90" },
    .{ .name = "Ntilde", .bytes = "\xC3\x91" },
    .{ .name = "Ograve", .bytes = "\xC3\x92" },
    .{ .name = "Oacute", .bytes = "\xC3\x93" },
    .{ .name = "Ocirc", .bytes = "\xC3\x94" },
    .{ .name = "Otilde", .bytes = "\xC3\x95" },
    .{ .name = "Ouml", .bytes = "\xC3\x96" },
    .{ .name = "times", .bytes = "\xC3\x97" },
    .{ .name = "Oslash", .bytes = "\xC3\x98" },
    .{ .name = "Ugrave", .bytes = "\xC3\x99" },
    .{ .name = "Uacute", .bytes = "\xC3\x9A" },
    .{ .name = "Ucirc", .bytes = "\xC3\x9B" },
    .{ .name = "Uuml", .bytes = "\xC3\x9C" },
    .{ .name = "Yacute", .bytes = "\xC3\x9D" },
    .{ .name = "THORN", .bytes = "\xC3\x9E" },
    .{ .name = "szlig", .bytes = "\xC3\x9F" },
    .{ .name = "agrave", .bytes = "\xC3\xA0" },
    .{ .name = "aacute", .bytes = "\xC3\xA1" },
    .{ .name = "acirc", .bytes = "\xC3\xA2" },
    .{ .name = "atilde", .bytes = "\xC3\xA3" },
    .{ .name = "auml", .bytes = "\xC3\xA4" },
    .{ .name = "aring", .bytes = "\xC3\xA5" },
    .{ .name = "aelig", .bytes = "\xC3\xA6" },
    .{ .name = "ccedil", .bytes = "\xC3\xA7" },
    .{ .name = "egrave", .bytes = "\xC3\xA8" },
    .{ .name = "eacute", .bytes = "\xC3\xA9" },
    .{ .name = "ecirc", .bytes = "\xC3\xAA" },
    .{ .name = "euml", .bytes = "\xC3\xAB" },
    .{ .name = "igrave", .bytes = "\xC3\xAC" },
    .{ .name = "iacute", .bytes = "\xC3\xAD" },
    .{ .name = "icirc", .bytes = "\xC3\xAE" },
    .{ .name = "iuml", .bytes = "\xC3\xAF" },
    .{ .name = "eth", .bytes = "\xC3\xB0" },
    .{ .name = "ntilde", .bytes = "\xC3\xB1" },
    .{ .name = "ograve", .bytes = "\xC3\xB2" },
    .{ .name = "oacute", .bytes = "\xC3\xB3" },
    .{ .name = "ocirc", .bytes = "\xC3\xB4" },
    .{ .name = "otilde", .bytes = "\xC3\xB5" },
    .{ .name = "ouml", .bytes = "\xC3\xB6" },
    .{ .name = "divide", .bytes = "\xC3\xB7" },
    .{ .name = "oslash", .bytes = "\xC3\xB8" },
    .{ .name = "ugrave", .bytes = "\xC3\xB9" },
    .{ .name = "uacute", .bytes = "\xC3\xBA" },
    .{ .name = "ucirc", .bytes = "\xC3\xBB" },
    .{ .name = "uuml", .bytes = "\xC3\xBC" },
    .{ .name = "yacute", .bytes = "\xC3\xBD" },
    .{ .name = "thorn", .bytes = "\xC3\xBE" },
    .{ .name = "yuml", .bytes = "\xC3\xBF" },
    // Extended Latin
    .{ .name = "Dcaron", .bytes = "\xC4\x8E" }, // U+010E
    // General punctuation, symbols
    .{ .name = "ndash", .bytes = "\xE2\x80\x93" },
    .{ .name = "mdash", .bytes = "\xE2\x80\x94" },
    .{ .name = "lsquo", .bytes = "\xE2\x80\x98" },
    .{ .name = "rsquo", .bytes = "\xE2\x80\x99" },
    .{ .name = "sbquo", .bytes = "\xE2\x80\x9A" },
    .{ .name = "ldquo", .bytes = "\xE2\x80\x9C" },
    .{ .name = "rdquo", .bytes = "\xE2\x80\x9D" },
    .{ .name = "bdquo", .bytes = "\xE2\x80\x9E" },
    .{ .name = "dagger", .bytes = "\xE2\x80\xA0" },
    .{ .name = "Dagger", .bytes = "\xE2\x80\xA1" },
    .{ .name = "bull", .bytes = "\xE2\x80\xA2" },
    .{ .name = "hellip", .bytes = "\xE2\x80\xA6" },
    .{ .name = "permil", .bytes = "\xE2\x80\xB0" },
    .{ .name = "prime", .bytes = "\xE2\x80\xB2" },
    .{ .name = "Prime", .bytes = "\xE2\x80\xB3" },
    .{ .name = "lsaquo", .bytes = "\xE2\x80\xB9" },
    .{ .name = "rsaquo", .bytes = "\xE2\x80\xBA" },
    .{ .name = "trade", .bytes = "\xE2\x84\xA2" }, // U+2122
    // Letterlike symbols
    .{ .name = "HilbertSpace", .bytes = "\xE2\x84\x8B" }, // U+210B
    // Math
    .{ .name = "DifferentialD", .bytes = "\xE2\x85\x86" }, // U+2146
    .{ .name = "ClockwiseContourIntegral", .bytes = "\xE2\x88\xB2" }, // U+2232
    // Multi-codepoint: ≧̸ = U+2267 U+0338
    .{ .name = "ngE", .bytes = "\xE2\x89\xA7\xCC\xB8" },
    // Arrows, math operators
    .{ .name = "larr", .bytes = "\xE2\x86\x90" },
    .{ .name = "uarr", .bytes = "\xE2\x86\x91" },
    .{ .name = "rarr", .bytes = "\xE2\x86\x92" },
    .{ .name = "darr", .bytes = "\xE2\x86\x93" },
    .{ .name = "harr", .bytes = "\xE2\x86\x94" },
    .{ .name = "lArr", .bytes = "\xE2\x87\x90" },
    .{ .name = "rArr", .bytes = "\xE2\x87\x92" },
    // Miscellaneous
    .{ .name = "spades", .bytes = "\xE2\x99\xA0" },
    .{ .name = "clubs", .bytes = "\xE2\x99\xA3" },
    .{ .name = "hearts", .bytes = "\xE2\x99\xA5" },
    .{ .name = "diams", .bytes = "\xE2\x99\xA6" },
};

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

test "heading" {
    try ok("# Heading", "<h1>Heading</h1>\n");
    try ok("## Level 2", "<h2>Level 2</h2>\n");
    try ok("### Level 3", "<h3>Level 3</h3>\n");
}

test "setext heading" {
    try ok("Title\n=====", "<h1>Title</h1>\n");
    try ok("Title\n-----", "<h2>Title</h2>\n");
}

test "thematic break" {
    try ok("---", "<hr />\n");
    try ok("***", "<hr />\n");
    try ok("___", "<hr />\n");
}

test "paragraph" {
    try ok("Hello world", "<p>Hello world</p>\n");
}

test "multi-line paragraph with soft break" {
    try ok("line one\nline two", "<p>line one\nline two</p>\n");
}

test "emphasis and strong" {
    try ok("*em*", "<p><em>em</em></p>\n");
    try ok("**bold**", "<p><strong>bold</strong></p>\n");
    try ok("_em_", "<p><em>em</em></p>\n");
    try ok("__bold__", "<p><strong>bold</strong></p>\n");
}

test "link" {
    try ok("[text](https://example.com)", "<p><a href=\"https://example.com\">text</a></p>\n");
}

test "image" {
    try ok("![alt](img.png)", "<p><img src=\"img.png\" alt=\"alt\" /></p>\n");
}

test "autolink" {
    try ok("<https://example.com>", "<p><a href=\"https://example.com\">https://example.com</a></p>\n");
}

test "code span" {
    try ok("`code`", "<p><code>code</code></p>\n");
}

test "indented code block" {
    try ok("    hello", "<pre><code>hello\n</code></pre>\n");
}

test "fenced code block" {
    try ok("```\ncode\n```", "<pre><code>code\n</code></pre>\n");
    try ok("```zig\nconst x = 1;\n```", "<pre><code class=\"language-zig\">const x = 1;\n</code></pre>\n");
}

test "blockquote" {
    try ok("> quote", "<blockquote>\n<p>quote</p>\n</blockquote>\n");
}

test "tight unordered list" {
    try ok("- a\n- b\n- c", "<ul>\n<li>a</li>\n<li>b</li>\n<li>c</li>\n</ul>\n");
}

test "loose unordered list" {
    try ok("- a\n\n- b", "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n");
}

test "ordered list" {
    try ok("1. first\n2. second", "<ol>\n<li>first</li>\n<li>second</li>\n</ol>\n");
}

test "ordered list non-one start" {
    try ok("3. first\n4. second", "<ol start=\"3\">\n<li>first</li>\n<li>second</li>\n</ol>\n");
}

test "backslash escape" {
    try ok("\\*not em\\*", "<p>*not em*</p>\n");
}

test "hard break" {
    try ok("line one  \nline two", "<p>line one<br />\nline two</p>\n");
}

test "link reference" {
    try ok("[foo]: /url \"title\"\n\n[foo]", "<p><a href=\"/url\" title=\"title\">foo</a></p>\n");
}

test "link reference forward" {
    try ok("[foo]\n\n[foo]: /url", "<p><a href=\"/url\">foo</a></p>\n");
}

test "link reference collapsed" {
    try ok("[foo]: /url\n\n[foo][]", "<p><a href=\"/url\">foo</a></p>\n");
}

test "link with parens in url" {
    try ok("[link](foo(and(bar)))", "<p><a href=\"foo(and(bar))\">link</a></p>\n");
}

test "link with angle bracket dest" {
    try ok("[link](</my uri>)", "<p><a href=\"/my%20uri\">link</a></p>\n");
}

test "link with title styles" {
    try ok("[link](/url \"title\")", "<p><a href=\"/url\" title=\"title\">link</a></p>\n");
    try ok("[link](/url 'title')", "<p><a href=\"/url\" title=\"title\">link</a></p>\n");
    try ok("[link](/url (title))", "<p><a href=\"/url\" title=\"title\">link</a></p>\n");
}

test "link rejects space in bare url" {
    try ok("[link](/my uri)", "<p>[link](/my uri)</p>\n");
}

test "gfm table basic" {
    try ok(
        "a | b\n" ++
            "---|---\n" ++
            "1 | 2",
        "<table>\n" ++
            "<thead>\n" ++
            "<tr>\n" ++
            "<th>a</th>\n" ++
            "<th>b</th>\n" ++
            "</tr>\n" ++
            "</thead>\n" ++
            "<tbody>\n" ++
            "<tr>\n" ++
            "<td>1</td>\n" ++
            "<td>2</td>\n" ++
            "</tr>\n" ++
            "</tbody>\n" ++
            "</table>\n",
    );
}

fn okMermaid(src: []const u8, mfn: ?*const fn (std.mem.Allocator, []const u8) anyerror![]const u8, expected: []const u8) !void {
    const allocator = tst.allocator;
    var parser = Parser.init();
    defer parser.deinit(allocator);
    var res = try parser.parseMarkdown(allocator, src);
    defer res.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try renderToWriterWithMermaid(allocator, &aw.writer, res, mfn);
    const out = try aw.toOwnedSlice();
    defer allocator.free(out);
    try tst.expectEqualStrings(expected, out);
}

fn stubSvg(alloc: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
    return alloc.dupe(u8, "<svg>mock</svg>");
}

fn stubSvgError(_: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
    return error.RenderFailed;
}

test "mermaid block renders as figure" {
    try okMermaid(
        "```mermaid\ngraph LR\nA-->B\n```",
        stubSvg,
        "<figure class=\"mermaid-diagram\">\n<svg>mock</svg></figure>\n",
    );
}

test "mermaidjs block renders as figure" {
    try okMermaid(
        "```mermaidjs\ngraph LR\nA-->B\n```",
        stubSvg,
        "<figure class=\"mermaid-diagram\">\n<svg>mock</svg></figure>\n",
    );
}

test "mermaid renderer error falls back to code block" {
    try okMermaid(
        "```mermaid\ngraph LR\nA-->B\n```",
        stubSvgError,
        "<pre><code class=\"language-mermaid\">graph LR\nA--&gt;B\n</code></pre>\n",
    );
}

test "mermaid null renderer falls back to code block" {
    try okMermaid(
        "```mermaid\ngraph LR\nA-->B\n```",
        null,
        "<pre><code class=\"language-mermaid\">graph LR\nA--&gt;B\n</code></pre>\n",
    );
}

test "non-mermaid lang unaffected by mermaid renderer" {
    try okMermaid(
        "```zig\nconst x = 1;\n```",
        stubSvg,
        "<pre><code class=\"language-zig\">const x = 1;\n</code></pre>\n",
    );
}
