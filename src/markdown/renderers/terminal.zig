//! Terminal (ANSI) renderer for the Markdown AST.
//!
//! Renders a parsed Markdown document using ANSI escape sequences for
//! display in modern terminal emulators.  Supports bold, italic, underline,
//! dim, strikethrough, and colour — similar to the output of tools like
//! `bat`, `glow`, or `mdcat`.
//!
//! ## Style mapping
//!
//!   Markdown element        ANSI rendering
//!   ─────────────────────   ──────────────────────────────────
//!   # Heading 1             Bold + Magenta, underlined
//!   ## Heading 2            Bold + Cyan
//!   ### Heading 3            Bold + Green
//!   #### Heading 4+         Bold + Yellow
//!   **strong**              Bold
//!   *emphasis*              Italic
//!   `code span`             Red on dark background
//!   [link](url)             Underline + Blue, URL in dim
//!   ![image](url)           Inline image (iTerm2/Kitty protocol) or fallback
//!   > blockquote            Dim + "│ " prefix
//!   ```code block```        Green on dark background, boxed
//!   ---                     Dim horizontal rule
//!   - list item             Bullet "• " prefix
//!   1. list item            Numbered prefix
//!   <html>                  Dim (passed through)
//!   footnote                Superscript-style
//!
//! ## Terminal width
//!
//! Horizontal rules are rendered to 60 columns.  No line-wrapping is
//! performed — the terminal handles soft wrapping.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tst = std.testing;

const AST = @import("../ast.zig");
const Parser = @import("../parser.zig");

// ── ANSI escape helpers ──────────────────────────────────────────────────────

const ESC = "\x1b[";
const RESET = ESC ++ "0m";

// Attributes
const BOLD = ESC ++ "1m";
const DIM = ESC ++ "2m";
const ITALIC = ESC ++ "3m";
const UNDERLINE = ESC ++ "4m";
const STRIKETHROUGH = ESC ++ "9m";

// Foreground colours
const FG_RED = ESC ++ "31m";
const FG_GREEN = ESC ++ "32m";
const FG_YELLOW = ESC ++ "33m";
const FG_BLUE = ESC ++ "34m";
const FG_MAGENTA = ESC ++ "35m";
const FG_CYAN = ESC ++ "36m";
const FG_WHITE = ESC ++ "37m";
const FG_BRIGHT_BLACK = ESC ++ "90m";

// Background colours
const BG_DARK = ESC ++ "48;5;236m"; // dark grey background for code

// OSC 8 hyperlinks — makes URLs clickable in modern terminals.
// Format: OSC 8 ; params ; URI ST  …visible text…  OSC 8 ; ; ST
// See https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda
const OSC8_BEGIN = "\x1b]8;;"; // followed by the URL
const OSC8_END = "\x1b\\"; // ST (String Terminator) — closes the URI and the final hyperlink

// iTerm2 inline image protocol (also supported by WezTerm, Mintty, Konsole).
// Format: OSC 1337 ; File=[args] : <base64 data> ST
// See https://iterm2.com/documentation-images.html
const OSC1337_FILE_BEGIN = "\x1b]1337;File=";
// ST for iTerm2: use BEL (\x07) which has wider compat than ESC \\
const IMG_ST = "\x07";

/// Kitty graphics protocol transmit command.
/// Format: ESC_graphics <payload> ESC_graphics_end
const KITTY_IMG_BEGIN = "\x1b_Ga=T,f=100,";
const KITTY_IMG_END = "\x1b\\";

/// Check if the current terminal supports inline images via the
/// Inline image protocol supported by the terminal.
/// Ghostty ≥1.1 supports both Kitty and iTerm2 protocols; we prefer
/// iTerm2 for Ghostty because it's simpler (single payload, any format).
const ImageProto = enum { none, iterm2, kitty };

fn detectImageProtocol() ImageProto {
    // VS Code's integrated terminal does NOT support inline images even
    // when the outer terminal (e.g. Ghostty) does — bail out early.
    if (std.posix.getenv("TERM_PROGRAM")) |tp| {
        if (std.mem.eql(u8, tp, "vscode")) return .none;
    }
    // Ghostty ≥1.1 supports the iTerm2 inline image protocol, which is
    // simpler (single payload, terminal auto-detects format).
    if (std.posix.getenv("GHOSTTY_RESOURCES_DIR")) |_| return .iterm2;
    // Check TERM_PROGRAM
    if (std.posix.getenv("TERM_PROGRAM")) |tp| {
        if (std.mem.eql(u8, tp, "iTerm.app") or
            std.mem.eql(u8, tp, "WezTerm") or
            std.mem.eql(u8, tp, "mintty") or
            std.mem.eql(u8, tp, "ghostty"))
        {
            return .iterm2;
        }
        if (std.mem.eql(u8, tp, "kitty")) return .kitty;
    }
    // Konsole supports iterm2 protocol
    if (std.posix.getenv("KONSOLE_VERSION")) |_| return .iterm2;
    // Kitty sets TERM=xterm-kitty
    if (std.posix.getenv("TERM")) |term| {
        if (std.mem.indexOf(u8, term, "kitty") != null) return .kitty;
        if (std.mem.indexOf(u8, term, "ghostty") != null) return .iterm2;
    }
    return .none;
}

/// Recognised image file extensions.
fn isImageExtension(path: []const u8) bool {
    const exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".svg", ".ico", ".tiff", ".tif" };
    const lower_dot = if (std.mem.lastIndexOfScalar(u8, path, '.')) |i| path[i..] else return false;
    for (exts) |ext| {
        if (std.ascii.eqlIgnoreCase(lower_dot, ext)) return true;
    }
    return false;
}

/// Try to read a local file given a (possibly relative) path.
/// Returns owned slice or null on failure.
fn readLocalFile(allocator: Allocator, path: []const u8) ?[]u8 {
    // Reject URLs — only handle local paths
    if (std.mem.startsWith(u8, path, "http://") or
        std.mem.startsWith(u8, path, "https://") or
        std.mem.startsWith(u8, path, "data:"))
    {
        return null;
    }
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    // Cap at 10 MiB to avoid runaway reads
    return file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch null;
}

/// Write an iTerm2 inline image sequence.
/// `data` is the raw file bytes; they are base64-encoded into the output.
fn writeIterm2Image(w: anytype, data: []const u8, alt: []const u8, allocator: Allocator) !void {
    const b64_len = std.base64.standard.Encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, b64_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, data);

    // OSC 1337 ; File=inline=1;size=<n>;name=<b64name> : <base64> ST
    try w.writeAll(OSC1337_FILE_BEGIN);
    try w.print("inline=1;size={d}", .{data.len});
    if (alt.len > 0) {
        // name param is base64-encoded filename/alt text
        const alt_b64_len = std.base64.standard.Encoder.calcSize(alt.len);
        const alt_encoded = try allocator.alloc(u8, alt_b64_len);
        defer allocator.free(alt_encoded);
        _ = std.base64.standard.Encoder.encode(alt_encoded, alt);
        try w.writeAll(";name=");
        try w.writeAll(alt_encoded);
    }
    try w.writeByte(':');
    try w.writeAll(encoded);
    try w.writeAll(IMG_ST);
}

/// Write a Kitty graphics protocol inline image by file path.
/// Uses `t=f` (transmit by file path) so the terminal loads and decodes
/// the image itself — works with any format the terminal supports
/// (PNG, JPEG, GIF, WebP, etc.) without us needing to transcode.
fn writeKittyImagePath(w: anytype, path: []const u8, allocator: Allocator) !void {
    // Kitty protocol wants the path base64-encoded when using t=f
    // Resolve to absolute path first
    const abs_path = std.fs.cwd().realpathAlloc(allocator, path) catch return;
    defer allocator.free(abs_path);

    const b64_len = std.base64.standard.Encoder.calcSize(abs_path.len);
    const encoded_path = try allocator.alloc(u8, b64_len);
    defer allocator.free(encoded_path);
    _ = std.base64.standard.Encoder.encode(encoded_path, abs_path);

    // Single-payload command: ESC_G a=T,t=f ; <base64-path> ST
    // a=T = transmit and display, t=f = file path (terminal auto-detects format)
    try w.writeAll("\x1b_Ga=T,t=f;");
    try w.writeAll(encoded_path);
    try w.writeAll(KITTY_IMG_END);
}

/// Write a Kitty graphics protocol inline image from raw data.
/// Used as fallback when file-path mode isn't possible.
fn writeKittyImageData(w: anytype, data: []const u8, allocator: Allocator) !void {
    const b64_len = std.base64.standard.Encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, b64_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, data);

    // Kitty sends in chunks of up to 4096 base64 chars.
    // m=1 means more data follows; m=0 means last chunk.
    var offset: usize = 0;
    const chunk_size: usize = 4096;
    var first = true;
    while (offset < encoded.len) {
        const end = @min(offset + chunk_size, encoded.len);
        const more: u8 = if (end < encoded.len) '1' else '0';
        if (first) {
            try w.print("\x1b_Ga=T,f=100,m={c};", .{more});
            first = false;
        } else {
            try w.print("\x1b_Gm={c};", .{more});
        }
        try w.writeAll(encoded[offset..end]);
        try w.writeAll(KITTY_IMG_END);
        offset = end;
    }
}

// ── Heading styles ───────────────────────────────────────────────────────────

const heading_styles = [6]struct { prefix: []const u8, suffix: []const u8 }{
    // H1: bold + magenta + underline
    .{ .prefix = BOLD ++ FG_MAGENTA ++ UNDERLINE, .suffix = RESET },
    // H2: bold + cyan
    .{ .prefix = BOLD ++ FG_CYAN, .suffix = RESET },
    // H3: bold + green
    .{ .prefix = BOLD ++ FG_GREEN, .suffix = RESET },
    // H4: bold + yellow
    .{ .prefix = BOLD ++ FG_YELLOW, .suffix = RESET },
    // H5: bold + blue
    .{ .prefix = BOLD ++ FG_BLUE, .suffix = RESET },
    // H6: bold + dim
    .{ .prefix = BOLD ++ DIM, .suffix = RESET },
};

const HR_WIDTH = 60;

// ── Helpers ──────────────────────────────────────────────────────────────────

fn writeNTimes(w: anytype, byte: u8, n: usize) !void {
    for (0..n) |_| try w.writeByte(byte);
}

/// Merge adjacent `.text` inlines into a single string.
fn mergedTextRun(items: []const AST.Inline, start: usize, allocator: Allocator) !struct { text: []const u8, consumed: usize, allocated: bool } {
    const first = items[start].text.content;
    var end = start + 1;
    while (end < items.len) {
        if (items[end] != .text) break;
        end += 1;
    }
    const consumed = end - start;
    if (consumed == 1) return .{ .text = first, .consumed = 1, .allocated = false };

    var buf = std.ArrayList(u8){};
    for (items[start..end]) |item| try buf.appendSlice(allocator, item.text.content);
    return .{ .text = try buf.toOwnedSlice(allocator), .consumed = consumed, .allocated = true };
}

// ── Inline renderer ──────────────────────────────────────────────────────────

fn renderInlineList(w: anytype, items: []const AST.Inline, allocator: Allocator) !void {
    var i: usize = 0;
    while (i < items.len) {
        if (items[i] == .text) {
            const run = try mergedTextRun(items, i, allocator);
            defer if (run.allocated) allocator.free(run.text);
            try w.writeAll(run.text);
            i += run.consumed;
        } else {
            try renderInline(w, items[i], allocator);
            i += 1;
        }
    }
}

fn renderInline(w: anytype, inl: AST.Inline, allocator: Allocator) !void {
    switch (inl) {
        .text => |t| try w.writeAll(t.content),
        .emphasis => |em| {
            try w.writeAll(ITALIC);
            for (em.children.items) |child| try renderInline(w, child, allocator);
            try w.writeAll(RESET);
        },
        .strong => |s| {
            try w.writeAll(BOLD);
            for (s.children.items) |child| try renderInline(w, child, allocator);
            try w.writeAll(RESET);
        },
        .code_span => |cs| {
            try w.writeAll(FG_RED ++ BG_DARK);
            try w.writeByte(' ');
            try w.writeAll(cs.content);
            try w.writeByte(' ');
            try w.writeAll(RESET);
        },
        .link => |lnk| {
            // OSC 8 clickable hyperlink with underlined blue text
            try w.writeAll(OSC8_BEGIN);
            try w.writeAll(lnk.destination.url);
            try w.writeAll(OSC8_END);
            try w.writeAll(UNDERLINE ++ FG_BLUE);
            for (lnk.children.items) |child| try renderInline(w, child, allocator);
            try w.writeAll(RESET);
            try w.writeAll(OSC8_BEGIN);
            try w.writeAll(OSC8_END); // close hyperlink
            try w.writeAll(DIM);
            try w.writeAll(" (");
            try w.writeAll(lnk.destination.url);
            try w.writeAll(")");
            try w.writeAll(RESET);
        },
        .image => |img| {
            const proto = detectImageProtocol();

            // Try to display inline image for local files in capable terminals
            if (proto != .none and isImageExtension(img.destination.url)) {
                const is_local = !std.mem.startsWith(u8, img.destination.url, "http://") and
                    !std.mem.startsWith(u8, img.destination.url, "https://") and
                    !std.mem.startsWith(u8, img.destination.url, "data:");

                if (is_local) {
                    switch (proto) {
                        .kitty => {
                            // Kitty protocol: use file-path transmission (t=f).
                            // The terminal loads the file directly — no need to
                            // read it into memory or worry about image format.
                            try writeKittyImagePath(w, img.destination.url, allocator);
                            try w.writeByte('\n');
                            if (img.alt_text.len > 0) {
                                try w.writeAll(DIM ++ FG_YELLOW);
                                try w.writeAll(img.alt_text);
                                try w.writeAll(RESET);
                            }
                            return;
                        },
                        .iterm2 => {
                            if (readLocalFile(allocator, img.destination.url)) |data| {
                                defer allocator.free(data);
                                try writeIterm2Image(w, data, img.alt_text, allocator);
                                try w.writeByte('\n');
                                if (img.alt_text.len > 0) {
                                    try w.writeAll(DIM ++ FG_YELLOW);
                                    try w.writeAll(img.alt_text);
                                    try w.writeAll(RESET);
                                }
                                return;
                            }
                        },
                        .none => {},
                    }
                }
            }

            // Fallback: 🖼 alt (url) — URL is a clickable OSC 8 hyperlink
            try w.writeAll(FG_YELLOW);
            try w.writeAll("🖼 ");
            try w.writeAll(img.alt_text);
            try w.writeAll(RESET);
            try w.writeAll(DIM);
            try w.writeAll(" (");
            try w.writeAll(OSC8_BEGIN);
            try w.writeAll(img.destination.url);
            try w.writeAll(OSC8_END);
            try w.writeAll(FG_BLUE ++ UNDERLINE);
            try w.writeAll(img.destination.url);
            try w.writeAll(RESET ++ DIM);
            try w.writeAll(OSC8_BEGIN);
            try w.writeAll(OSC8_END);
            try w.writeAll(")");
            try w.writeAll(RESET);
        },
        .autolink => |al| {
            try w.writeAll(OSC8_BEGIN);
            if (al.is_email) try w.writeAll("mailto:");
            try w.writeAll(al.url);
            try w.writeAll(OSC8_END);
            try w.writeAll(UNDERLINE ++ FG_BLUE);
            try w.writeAll(al.url);
            try w.writeAll(RESET);
            try w.writeAll(OSC8_BEGIN);
            try w.writeAll(OSC8_END);
        },
        .footnote_reference => |fr| {
            try w.writeAll(FG_CYAN ++ DIM ++ "[^");
            try w.writeAll(fr.label);
            try w.writeByte(']');
            try w.writeAll(RESET);
        },
        .hard_break => try w.writeByte('\n'),
        .soft_break => try w.writeByte('\n'),
        .html_in_line => |hi| {
            try w.writeAll(DIM);
            try w.writeAll(hi.content);
            try w.writeAll(RESET);
        },
    }
}

// ── Block renderer ───────────────────────────────────────────────────────────

fn renderBlock(w: anytype, block: AST.Block, indent: usize, bq_depth: usize, allocator: Allocator) !void {
    switch (block) {
        .table => {},

        .heading => |h| {
            const idx: usize = if (h.level >= 1 and h.level <= 6) h.level - 1 else 5;
            const style = heading_styles[idx];

            try writeIndent(w, indent);
            try writeBlockquotePrefix(w, bq_depth);

            // Print the heading marker
            try w.writeAll(style.prefix);
            for (0..h.level) |_| try w.writeByte('#');
            try w.writeByte(' ');
            // Render inline content
            try renderInlineList(w, h.children.items, allocator);
            try w.writeAll(style.suffix);
            try w.writeByte('\n');
        },
        .paragraph => |p| {
            try writeIndent(w, indent);
            try writeBlockquotePrefix(w, bq_depth);
            try renderInlineList(w, p.children.items, allocator);
            try w.writeByte('\n');
        },
        .code_block => |cb| {
            // Indented code block — render with green text on dark bg
            try writeIndent(w, indent);
            try writeBlockquotePrefix(w, bq_depth);
            try w.writeAll(FG_GREEN ++ BG_DARK);
            var it = std.mem.splitScalar(u8, cb.content, '\n');
            var first = true;
            while (it.next()) |line| {
                if (!first) {
                    try writeIndent(w, indent);
                    try writeBlockquotePrefix(w, bq_depth);
                }
                try w.writeAll("  ");
                try w.writeAll(line);
                try w.writeAll("  ");
                if (it.peek() != null) try w.writeByte('\n');
                first = false;
            }
            try w.writeAll(RESET);
            try w.writeByte('\n');
        },
        .fenced_code_block => |fcb| {
            try writeIndent(w, indent);
            try writeBlockquotePrefix(w, bq_depth);
            // Language tag line
            if (fcb.language) |lang| {
                try w.writeAll(DIM ++ "╭─");
                try w.writeAll(lang);
                try w.writeAll(RESET);
            } else {
                try w.writeAll(DIM ++ "╭─");
                try w.writeAll(RESET);
            }
            try w.writeByte('\n');

            // Code lines
            var it = std.mem.splitScalar(u8, fcb.content, '\n');
            while (it.next()) |line| {
                if (line.len == 0 and it.peek() == null) break;
                try writeIndent(w, indent);
                try writeBlockquotePrefix(w, bq_depth);
                try w.writeAll(DIM ++ "│ " ++ RESET);
                try w.writeAll(FG_GREEN);
                try w.writeAll(line);
                try w.writeAll(RESET);
                try w.writeByte('\n');
            }

            // Bottom border
            try writeIndent(w, indent);
            try writeBlockquotePrefix(w, bq_depth);
            try w.writeAll(DIM ++ "╰─" ++ RESET);
            try w.writeByte('\n');
        },
        .blockquote => |bq| {
            for (bq.children.items) |child| {
                try renderBlock(w, child, indent, bq_depth + 1, allocator);
            }
        },
        .list => |lst| {
            for (lst.items.items, 0..) |item, idx| {
                for (item.children.items, 0..) |child, ci| {
                    if (ci == 0) {
                        // First block in item gets the bullet/number prefix
                        try writeIndent(w, indent);
                        try writeBlockquotePrefix(w, bq_depth);
                        if (lst.type == .ordered) {
                            const start_num = if (lst.start) |s| s else 1;
                            try w.print(FG_CYAN ++ "{d}." ++ RESET ++ " ", .{start_num + idx});
                        } else {
                            try w.writeAll(FG_CYAN ++ "• " ++ RESET);
                        }
                        // Render first child's content inline (unwrap paragraph)
                        switch (child) {
                            .paragraph => |p| {
                                try renderInlineList(w, p.children.items, allocator);
                                try w.writeByte('\n');
                                if (!lst.tight) try w.writeByte('\n');
                            },
                            else => {
                                try w.writeByte('\n');
                                try renderBlock(w, child, indent + 3, bq_depth, allocator);
                            },
                        }
                    } else {
                        // Subsequent blocks in the same item are indented
                        try renderBlock(w, child, indent + 3, bq_depth, allocator);
                        if (!lst.tight and child == .paragraph) try w.writeByte('\n');
                    }
                }
            }
        },
        .thematic_break => {
            try writeIndent(w, indent);
            try writeBlockquotePrefix(w, bq_depth);
            try w.writeAll(DIM);
            for (0..HR_WIDTH) |_| try w.writeAll("─");
            try w.writeAll(RESET);
            try w.writeByte('\n');
        },
        .html_block => |hb| {
            try writeIndent(w, indent);
            try writeBlockquotePrefix(w, bq_depth);
            try w.writeAll(DIM);
            try w.writeAll(hb.content);
            try w.writeAll(RESET);
        },
        .footnote_definition => |fd| {
            try writeIndent(w, indent);
            try writeBlockquotePrefix(w, bq_depth);
            try w.writeAll(FG_CYAN ++ DIM);
            try w.writeAll("[^");
            try w.writeAll(fd.label);
            try w.writeAll("]: ");
            try w.writeAll(RESET);
            for (fd.children.items, 0..) |child, ci| {
                if (ci == 0) {
                    switch (child) {
                        .paragraph => |p| {
                            try renderInlineList(w, p.children.items, allocator);
                            try w.writeByte('\n');
                        },
                        else => {
                            try w.writeByte('\n');
                            try renderBlock(w, child, indent + 4, bq_depth, allocator);
                        },
                    }
                } else {
                    try renderBlock(w, child, indent + 4, bq_depth, allocator);
                }
            }
        },
    }
}

fn writeIndent(w: anytype, n: usize) !void {
    for (0..n) |_| try w.writeByte(' ');
}

fn writeBlockquotePrefix(w: anytype, depth: usize) !void {
    for (0..depth) |_| {
        try w.writeAll(DIM ++ FG_WHITE ++ "│ " ++ RESET);
    }
}

// ── Top-level render ─────────────────────────────────────────────────────────

/// Render `doc` to an allocator-owned byte slice with ANSI terminal styling.
///
/// The caller owns the returned memory and must free it when done.
pub fn render(allocator: Allocator, doc: AST.Document) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    for (doc.children.items, 0..) |block, i| {
        try renderBlock(&aw.writer, block, 0, 0, allocator);
        // Add blank line between top-level blocks for readability
        if (i + 1 < doc.children.items.len) {
            // Don't double-space after thematic breaks
            if (block != .thematic_break) try aw.writer.writeByte('\n');
        }
    }
    return aw.toOwnedSlice();
}

// ── Tests ────────────────────────────────────────────────────────────────────

fn ok(markdown: []const u8, needle: []const u8) !void {
    const allocator = tst.allocator;
    var parser = Parser.init();
    defer parser.deinit(allocator);
    var doc = try parser.parseMarkdown(allocator, markdown);
    defer doc.deinit(allocator);
    const out = try render(allocator, doc);
    defer allocator.free(out);
    // For terminal output, ignore ANSI escape sequences when searching.
    try tst.expect(containsIgnoringAnsi(out, needle));
}

/// Strip all ANSI escape sequences so we can assert on visible text.
fn stripAnsi(allocator: Allocator, input: []const u8) ![]u8 {
    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\x1b' and i + 1 < input.len and input[i + 1] == '[') {
            // Skip ESC [ ... <letter>
            i += 2;
            while (i < input.len and (input[i] < 0x40 or input[i] > 0x7E)) : (i += 1) {}
            if (i < input.len) i += 1; // skip final byte
        } else {
            try buf.append(allocator, input[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Returns true if `needle` is found in `haystack` when ignoring ANSI escapes.
fn containsIgnoringAnsi(haystack: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    while (i < haystack.len) {
        if (haystack[i] == '\x1b' and i + 1 < haystack.len and haystack[i + 1] == '[') {
            // Skip ESC [ ... <letter>
            i += 2;
            while (i < haystack.len and (haystack[i] < 0x40 or haystack[i] > 0x7E)) : (i += 1) {}
            if (i < haystack.len) i += 1;
            continue;
        }

        // Attempt match from this position, skipping over ANSI sequences.
        var hi: usize = i;
        var nj: usize = 0;
        while (hi < haystack.len and nj < needle.len) {
            if (haystack[hi] == '\x1b' and hi + 1 < haystack.len and haystack[hi + 1] == '[') {
                hi += 2;
                while (hi < haystack.len and (haystack[hi] < 0x40 or haystack[hi] > 0x7E)) : (hi += 1) {}
                if (hi < haystack.len) hi += 1;
                continue;
            }
            if (haystack[hi] != needle[nj]) break;
            hi += 1;
            nj += 1;
        }
        if (nj == needle.len) return true;
        i += 1;
    }
    return false;
}

fn okStripped(markdown: []const u8, expected: []const u8) !void {
    const allocator = tst.allocator;
    var parser = Parser.init();
    defer parser.deinit(allocator);
    var doc = try parser.parseMarkdown(allocator, markdown);
    defer doc.deinit(allocator);
    const out = try render(allocator, doc);
    defer allocator.free(out);
    const stripped = try stripAnsi(allocator, out);
    defer allocator.free(stripped);
    try tst.expectEqualStrings(expected, stripped);
}

test "terminal: heading 1" {
    try okStripped("# Hello", "# Hello\n");
}

test "terminal: heading 2" {
    try okStripped("## World", "## World\n");
}

test "terminal: paragraph" {
    try okStripped("Hello world", "Hello world\n");
}

test "terminal: bold text" {
    try ok("**bold**", "bold");
}

test "terminal: italic text" {
    try ok("*italic*", "italic");
}

test "terminal: code span" {
    try ok("`code`", "code");
}

test "terminal: link" {
    try ok("[text](https://example.com)", "text");
    try ok("[text](https://example.com)", "https://example.com");
    // OSC 8 hyperlink escape must be present
    try ok("[text](https://example.com)", "\x1b]8;;");
}

test "terminal: unordered list" {
    try ok("- first\n- second", "• first");
    try ok("- first\n- second", "• second");
}

test "terminal: ordered list" {
    try ok("1. first\n2. second", "1. first");
    try ok("1. first\n2. second", "2. second");
}

test "terminal: fenced code block" {
    try ok("```zig\nconst x = 1;\n```", "const x = 1;");
    try ok("```zig\nconst x = 1;\n```", "zig");
}

test "terminal: blockquote" {
    try ok("> hello", "│ hello");
}

test "terminal: image" {
    try ok("![alt](img.png)", "🖼 alt");
    try ok("![alt](img.png)", "img.png");
}

test "terminal: thematic break renders" {
    const allocator = tst.allocator;
    var parser = Parser.init();
    defer parser.deinit(allocator);
    var doc = try parser.parseMarkdown(allocator, "---");
    defer doc.deinit(allocator);
    const out = try render(allocator, doc);
    defer allocator.free(out);
    // Just ensure it produces output without crashing
    try tst.expect(out.len > 0);
}

test "terminal: ANSI codes present" {
    const allocator = tst.allocator;
    var parser = Parser.init();
    defer parser.deinit(allocator);
    var doc = try parser.parseMarkdown(allocator, "**bold**");
    defer doc.deinit(allocator);
    const out = try render(allocator, doc);
    defer allocator.free(out);
    // Must contain ESC byte
    try tst.expect(std.mem.indexOf(u8, out, "\x1b[") != null);
}

test "terminal: footnote" {
    try ok("[^1]\n[^1]: content", "[^1]: content");
}

test "terminal: image extension detection" {
    try tst.expect(isImageExtension("photo.png"));
    try tst.expect(isImageExtension("photo.PNG"));
    try tst.expect(isImageExtension("photo.jpg"));
    try tst.expect(isImageExtension("photo.jpeg"));
    try tst.expect(isImageExtension("photo.gif"));
    try tst.expect(isImageExtension("photo.webp"));
    try tst.expect(isImageExtension("photo.svg"));
    try tst.expect(!isImageExtension("readme.md"));
    try tst.expect(!isImageExtension("data.json"));
    try tst.expect(!isImageExtension("noext"));
}

test "terminal: remote URLs are not read as local files" {
    const allocator = tst.allocator;
    try tst.expect(readLocalFile(allocator, "https://example.com/img.png") == null);
    try tst.expect(readLocalFile(allocator, "http://example.com/img.png") == null);
    try tst.expect(readLocalFile(allocator, "data:image/png;base64,abc") == null);
}

test "terminal: image with remote URL falls back to text" {
    // Remote URLs should always produce the fallback 🖼 text rendering
    try ok("![alt](https://example.com/img.png)", "🖼 alt");
    try ok("![alt](https://example.com/img.png)", "https://example.com/img.png");
}
