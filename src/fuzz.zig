//! Fuzz harness for zigmark's parser, renderers, and frontmatter parser.
//!
//! Run once (smoke test):       zig build fuzz
//! Coverage-guided fuzzing:     zig build fuzz --fuzz
//!
//! Targets take a `*std.testing.Smith` (the Zig 0.16 structured-input source)
//! and pull up to `max_input` bytes of fuzzer-chosen data via `smith.slice`.
//! Each target asserts only the absence of crashes/UB/leaks, not correctness.

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
