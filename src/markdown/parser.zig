//! Markdown parser — CommonMark 0.31.2 + GFM extensions.
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
//! **GFM extensions** supported (all 24/24 spec tests passing):
//!   - Tables (pipe-delimited, column alignment)
//!   - Task list items (`- [ ]` / `- [x]`)
//!   - Strikethrough (`~~text~~` → `<del>`)
//!   - Extended autolinks (bare `www.`, `http(s)://`, `ftp://`, email)
//!   - Disallowed raw HTML (dangerous tags have `<` escaped to `&lt;`)
//!
//! The public entry point is `parseMarkdown`.  All slice references in
//! the returned AST point into `input` or into owned buffers allocated
//! with the supplied allocator.  Calling `doc.deinit(allocator)` frees
//! every allocation the parser made.
//!
//! Block-level recognition is driven by the combinators and convenience
//! wrappers in the public `parsers` namespace.  Inline-level parsing uses
//! a hand-written state machine (CommonMark delimiter algorithm, extended
//! for `~~` strikethrough) because emphasis nesting cannot be expressed
//! as a pure combinator.
const std = @import("std");
const Allocator = std.mem.Allocator;
const tst = std.testing;
const mem = std.mem;

const AST = @import("ast.zig");

const Inline = @import("inline.zig");

// ── Public parser combinators & convenience wrappers ─────────────────────────

/// Low-level `mecha` parser combinators and convenience `try*` wrappers used
/// by the block parser.  Advanced callers may use the raw mecha parsers
/// directly; most code should prefer `parseMarkdown`.
pub const parsers = @import("combinators.zig");

// ── Ref map alias ─────────────────────────────────────────────────────────────

const RefMap = Inline.RefMap;

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

// ── Block parser ──────────────────────────────────────────────────────────────

const Self = @This();

/// When true, setext heading underlines inside paragraphs are disabled.
/// Used when re-parsing blockquote inner content that includes lazy
/// continuation lines which must not form setext headings.
has_lazy_setext: bool = false,
gfm: bool = true,

pub fn init() Self {
    return Self{};
}
pub fn deinit(_: *Self, _: Allocator) void {}

fn appendInlines(allocator: Allocator, dest: *std.ArrayList(AST.Inline), content: []const u8, ref_map: ?*const RefMap, gfm: bool) !void {
    var items = try Inline.parseInlineElements(allocator, content, ref_map, gfm);
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
                    if (try Inline.tryConsumeLinkRefDef(allocator, inner.items, bi, 5, ref_map)) |consumed| {
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
            if (try Inline.tryConsumeLinkRefDef(allocator, lines, i, 5, ref_map)) |consumed| {
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

        // GFM task list: detect "[ ] " or "[x] " / "[X] " at start of item content
        var effective_content = content;
        if (content.len >= 3 and content[0] == '[' and content[2] == ']') {
            const next_ok = content.len == 3 or content[3] == ' ' or content[3] == '\t' or content[3] == '\n';
            if (next_ok and content[1] == ' ') {
                item.task_list_checked = false;
                effective_content = content[@min(4, content.len)..];
            } else if (next_ok and (content[1] == 'x' or content[1] == 'X')) {
                item.task_list_checked = true;
                effective_content = content[@min(4, content.len)..];
            }
        }

        if (trimLine(effective_content).len > 0) {
            var inner = init();
            var inner_doc = try inner.parseMarkdownWithRefs(allocator, effective_content, ref_map);
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
    if (Inline.tryParseHtmlTag(t, 0)) |end| {
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
    doc.gfm = self.gfm;
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
            if (try Inline.tryConsumeLinkRefDef(allocator, lines, i, 5, @constCast(ref_map))) |consumed| {
                i += consumed;
                continue;
            }
        }

        // ATX heading
        if (parsers.tryAtxHeading(allocator, raw)) |h| {
            var heading = AST.Heading.init(allocator, h.level);
            const owned_content = try allocator.dupe(u8, h.content);
            heading.inline_source = owned_content;
            try appendInlines(allocator, &heading.children, owned_content, ref_map, self.gfm);
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
            try appendInlines(allocator, &para.children, fn_pc, ref_map, self.gfm);
            try fn_def.children.append(allocator, .{ .paragraph = para });
            try doc.children.append(allocator, .{ .footnote_definition = fn_def });
            i += 1;
            continue;
        }

        // GFM table (header line + delimiter line)
        {
            if (try tryTableStart(allocator, lines, i, ref_map, self.gfm)) |tres| {
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
                // A valid table start (header + matching delimiter) interrupts a paragraph.
                if (!is_first and isTableStart(lines, i)) break;
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
                try appendInlines(allocator, &para.children, pc, ref_map, self.gfm);
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

/// Returns true if lines[start] is a valid table header and lines[start+1] is a
/// matching delimiter row (same column count).  No allocation is performed.
fn isTableStart(lines: []const []const u8, start: usize) bool {
    if (start + 1 >= lines.len) return false;
    const header_line = lines[start];
    const delim_line = lines[start + 1];
    if (mem.indexOfScalar(u8, header_line, '|') == null) return false;

    // Count header columns (escape-aware)
    var header_cols: usize = 0;
    {
        const t = trimLine(header_line);
        var i: usize = 0;
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
        if (i < t.len and t[i] == '|') i += 1;
        while (i < t.len) {
            header_cols += 1;
            while (i < t.len) {
                if (t[i] == '\\' and i + 1 < t.len and t[i + 1] == '|') {
                    i += 2;
                } else if (t[i] == '|') {
                    break;
                } else {
                    i += 1;
                }
            }
            if (i < t.len and t[i] == '|') i += 1 else break;
        }
    }
    if (header_cols == 0) return false;

    const delim = parseTableDelimiter(delim_line) orelse return false;
    return delim.count == header_cols;
}

const TableDelimResult = struct {
    alignments: [64]AST.TableAlignment,
    count: usize,
};

/// Parse a GFM table delimiter row (e.g. `| :-- | ---: |`).
/// Returns the alignment for each column and the column count.
/// Returns null if the line is not a valid delimiter row.
fn parseTableDelimiter(line: []const u8) ?TableDelimResult {
    var result = TableDelimResult{ .alignments = undefined, .count = 0 };

    var i: usize = 0;
    const t = trimLine(line);
    if (t.len == 0) return null;

    // Consume optional leading '|'
    while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
    if (i < t.len and t[i] == '|') i += 1;

    while (i < t.len) {
        // Skip spaces before the cell
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
        if (i >= t.len) break;

        // A bare '|' here means a trailing pipe with nothing after — stop.
        if (t[i] == '|') break;

        // Parse one delimiter cell: optional ':', 1+ '-', optional ':'
        var left_colon = false;
        var right_colon = false;

        if (t[i] == ':') { left_colon = true; i += 1; }

        var dash_count: usize = 0;
        while (i < t.len and t[i] == '-') : (i += 1) dash_count += 1;
        if (dash_count < 1) return null;

        if (i < t.len and t[i] == ':') { right_colon = true; i += 1; }

        if (result.count >= result.alignments.len) return null;
        result.alignments[result.count] = if (left_colon and right_colon)
            .center
        else if (left_colon)
            .left
        else if (right_colon)
            .right
        else
            .none;
        result.count += 1;

        // Skip trailing spaces then consume the '|' separator (or stop at end)
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
        if (i >= t.len) break;
        if (t[i] == '|') i += 1 else return null; // invalid char after cell
    }

    if (result.count == 0) return null;
    return result;
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
        // Advance past cell content, treating '\|' as an escaped pipe (not a separator).
        while (i < t.len) {
            if (t[i] == '\\' and i + 1 < t.len and t[i + 1] == '|') {
                i += 2;
            } else if (t[i] == '|') {
                break;
            } else {
                i += 1;
            }
        }
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

/// Replace every `\|` in `src` with `|` (GFM table pipe escaping applies
/// at the cell level, before inline parsing — including inside code spans).
fn unescapeTablePipes(allocator: Allocator, src: []const u8) ![]const u8 {
    if (mem.indexOf(u8, src, "\\|") == null) return allocator.dupe(u8, src);
    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '\\' and i + 1 < src.len and src[i + 1] == '|') {
            try buf.append(allocator, '|');
            i += 2;
        } else {
            try buf.append(allocator, src[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn parseTableRow(
    allocator: Allocator,
    ref_map: ?*const RefMap,
    alignments: []const AST.TableAlignment,
    row_line: []const u8,
    table_row: *AST.TableRow,
    gfm: bool,
) !void {
    const cols = alignments.len;
    const raw_cells = splitTableRow(row_line, cols);

    for (raw_cells, 0..) |cell_src, idx| {
        var cell = AST.TableCell.init(allocator);
        const dup = try unescapeTablePipes(allocator, cell_src);
        cell.inline_source = dup;
        try appendInlines(allocator, &cell.children, dup, ref_map, gfm);
        try table_row.cells.append(allocator, cell);
        if (idx + 1 == cols) break;
    }
}

fn tryTableStart(
    allocator: Allocator,
    lines: []const []const u8,
    start: usize,
    ref_map: ?*const RefMap,
    gfm: bool,
) !?TableParseResult {
    if (start + 1 >= lines.len) return null;

    const header_line = lines[start];
    const delim_line = lines[start + 1];

    // Header must contain at least one '|'
    if (mem.indexOfScalar(u8, header_line, '|') == null) return null;

    // Count header columns, treating '\|' as an escaped pipe (not a separator).
    var header_cols: usize = 0;
    {
        const t = trimLine(header_line);
        var i: usize = 0;
        // Skip leading spaces and optional leading '|'
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
        if (i < t.len and t[i] == '|') i += 1;
        while (i < t.len) {
            header_cols += 1;
            while (i < t.len) {
                if (t[i] == '\\' and i + 1 < t.len and t[i + 1] == '|') {
                    i += 2;
                } else if (t[i] == '|') {
                    break;
                } else {
                    i += 1;
                }
            }
            if (i < t.len and t[i] == '|') i += 1 else break;
        }
    }

    if (header_cols == 0) return null;

    // Parse delimiter and require exact column-count match (GFM spec §4.1).
    const delim = parseTableDelimiter(delim_line) orelse return null;
    if (delim.count != header_cols) return null;

    const align_buf = try allocator.alloc(AST.TableAlignment, header_cols);
    defer allocator.free(align_buf);
    for (align_buf, 0..header_cols) |*dst, i| dst.* = delim.alignments[i];

    var table = AST.Table.init(allocator);
    // install alignments
    for (align_buf) |a| try table.alignments.append(allocator, a);

    // Header row
    try parseTableRow(allocator, ref_map, table.alignments.items, header_line, &table.header, gfm);

    // Body rows
    var i = start + 2;
    while (i < lines.len) : (i += 1) {
        const raw = lines[i];
        const t = trimLine(raw);
        if (t.len == 0) break;
        if (isStandaloneBlockStart(allocator, raw)) break;

        var row = AST.TableRow.init(allocator);
        try parseTableRow(allocator, ref_map, table.alignments.items, raw, &row, gfm);
        try table.body.append(allocator, row);
    }

    return .{ .table = table, .next_line = i };
}

test {
    _ = @import("test.zig");
    tst.refAllDecls(@This());
}
