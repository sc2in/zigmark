//! Fuzz harness for zigmark's parser, renderers, and frontmatter parser.
//!
//! Run once (smoke test):       zig build fuzz
//! Coverage-guided fuzzing:     zig build fuzz --fuzz
//!
//! Targets take a `*std.testing.Smith` (the Zig 0.16 structured-input source)
//! and pull up to `max_input` bytes of fuzzer-chosen data via `smith.slice`.
//! Most targets assert only the absence of crashes/UB/leaks, not correctness.
//! The exception is `fuzz_frontmatter_yaml_roundtrip`, which asserts a
//! serializer<->parser round-trip invariant (see its comment) — that is the
//! oracle that catches spurious `ParseFailure`s such as issue #81, which are
//! graceful errors the no-crash targets swallow.

const std = @import("std");
const zigmark = @import("zigmark");

const Smith = std.testing.Smith;
const max_input = 8192;

// ── Parser ────────────────────────────────────────────────────────────────────

test "fuzz_parse" {
    try std.testing.fuzz({}, fuzzParse, .{});
}

test "fuzz_parse_commonmark" {
    try std.testing.fuzz({}, fuzzParseCommonMark, .{});
}

// ── Parser + renderer ─────────────────────────────────────────────────────────

test "fuzz_parse_render_html" {
    try std.testing.fuzz({}, fuzzParseRenderHtml, .{});
}

test "fuzz_parse_render_html_safe" {
    try std.testing.fuzz({}, fuzzParseRenderHtmlSafe, .{});
}

test "fuzz_parse_render_markdown" {
    try std.testing.fuzz({}, fuzzParseRenderMarkdown, .{});
}

test "fuzz_parse_render_typst" {
    try std.testing.fuzz({}, fuzzParseRenderTypst, .{});
}

// ── Frontmatter ───────────────────────────────────────────────────────────────

test "fuzz_frontmatter_yaml" {
    try std.testing.fuzz({}, fuzzFrontmatterYaml, .{});
}

test "fuzz_frontmatter_toml" {
    try std.testing.fuzz({}, fuzzFrontmatterToml, .{});
}

test "fuzz_frontmatter_json" {
    try std.testing.fuzz({}, fuzzFrontmatterJson, .{});
}

test "fuzz_frontmatter_zon" {
    try std.testing.fuzz({}, fuzzFrontmatterZon, .{});
}

test "fuzz_frontmatter_yaml_roundtrip" {
    try std.testing.fuzz({}, fuzzFrontmatterYamlRoundtrip, .{});
}

// ── Implementations ───────────────────────────────────────────────────────────

fn fuzzParse(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var doc = zigmark.Parser.init().parseMarkdown(arena.allocator(), input) catch return;
    doc.deinit(arena.allocator());
}

fn fuzzParseCommonMark(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var doc = (zigmark.Parser{ .gfm = false }).parseMarkdown(arena.allocator(), input) catch return;
    doc.deinit(arena.allocator());
}

fn fuzzParseRenderHtml(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var doc = zigmark.Parser.init().parseMarkdown(alloc, input) catch return;
    defer doc.deinit(alloc);
    const out = zigmark.HTMLRenderer.render(alloc, doc) catch return;
    _ = out;
}

fn fuzzParseRenderHtmlSafe(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var doc = zigmark.Parser.init().parseMarkdown(alloc, input) catch return;
    defer doc.deinit(alloc);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    zigmark.renderHtmlWithOptions(alloc, &aw.writer, doc, .{ .safe = true }) catch return;
}

fn fuzzParseRenderMarkdown(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var doc = zigmark.Parser.init().parseMarkdown(alloc, input) catch return;
    defer doc.deinit(alloc);
    const out = zigmark.MarkdownRenderer.render(alloc, doc) catch return;
    _ = out;
}

fn fuzzParseRenderTypst(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var doc = zigmark.Parser.init().parseMarkdown(alloc, input) catch return;
    defer doc.deinit(alloc);
    const out = zigmark.typst.renderDocument(alloc, doc, .{}) catch return;
    _ = out;
}

fn fuzzFrontmatterYaml(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var fm = zigmark.Frontmatter.init(arena.allocator(), input, .yaml) catch return;
    fm.deinit();
}

fn fuzzFrontmatterToml(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var fm = zigmark.Frontmatter.init(arena.allocator(), input, .toml) catch return;
    fm.deinit();
}

fn fuzzFrontmatterJson(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var fm = zigmark.Frontmatter.init(arena.allocator(), input, .json) catch return;
    fm.deinit();
}

fn fuzzFrontmatterZon(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var fm = zigmark.Frontmatter.init(arena.allocator(), input, .zon) catch return;
    fm.deinit();
}

// A value byte drawn onto this alphabet lands as a word char, a space, or one
// of the plain-scalar *indicator* characters called out in issue #81 (`&`
// anchor, `*` alias, `!` tag, `- ` seq-item). Biasing toward spaces and
// indicators makes the fuzzer hit the "space + indicator" positions that used
// to abort the YAML parse mid plain-scalar. This is deliberately scoped to the
// indicator surface; interior quote / flow-bracket round-tripping is a
// separate class not covered here.
const scalar_alphabet = "abcdefgh  &*!-  ";

/// Round-trip oracle: a string value set into YAML front matter must survive
/// `serialize` -> `initFromMarkdown`. zigmark's emitter leaves interior
/// indicator characters unquoted (they are legal plain-scalar content), so if
/// the parser rejects them the document zigmark just produced fails to re-parse
/// — a serializer<->parser disagreement. Unlike the no-crash targets, the
/// re-parse error is NOT swallowed: it propagates and fails the fuzz iteration,
/// reporting the offending value (this is how issue #81 is re-caught).
fn fuzzFrontmatterYamlRoundtrip(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const raw = buf[0..smith.slice(&buf)];
    for (raw) |*b| b.* = scalar_alphabet[b.* % scalar_alphabet.len];
    // YAML strips leading/trailing whitespace from plain scalars, so surrounding
    // spaces cannot round-trip as a plain scalar — trim them to isolate the
    // indicator behaviour under test.
    const value = std.mem.trim(u8, raw, " ");
    if (value.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build the document programmatically so the first parse cannot fail on
    // syntax; the emitter alone decides whether `value` is quoted.
    var fm = zigmark.Frontmatter.init(alloc, "seed: 1", .yaml) catch return;
    defer fm.deinit();
    fm.set("v", .{ .string = value }) catch return;
    const out = fm.serialize(alloc) catch return;

    // Re-parse zigmark's own output — this MUST succeed and preserve `value`.
    var fm2 = try zigmark.Frontmatter.initFromMarkdown(alloc, out);
    defer fm2.deinit();
    const got = fm2.get("v") orelse return error.RoundTripLostValue;
    if (got != .string) return error.RoundTripChangedType;
    try std.testing.expectEqualStrings(value, got.string);
}
