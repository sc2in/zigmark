//! Fuzz harness for zigmark's parser, renderers, and frontmatter parser.
//!
//! Run once (smoke test):       zig build fuzz
//! Coverage-guided fuzzing:     zig build fuzz -- --fuzz

const std = @import("std");
const zigmark = @import("zigmark");

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

test "fuzz_parse_render_markdown" {
    try std.testing.fuzz({}, fuzzParseRenderMarkdown, .{});
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

// ── Implementations ───────────────────────────────────────────────────────────

fn fuzzParse(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var doc = zigmark.Parser.init().parseMarkdown(arena.allocator(), input) catch return;
    doc.deinit(arena.allocator());
}

fn fuzzParseCommonMark(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var doc = (zigmark.Parser{ .gfm = false }).parseMarkdown(arena.allocator(), input) catch return;
    doc.deinit(arena.allocator());
}

fn fuzzParseRenderHtml(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var doc = zigmark.Parser.init().parseMarkdown(alloc, input) catch return;
    defer doc.deinit(alloc);
    const out = zigmark.HTMLRenderer.render(alloc, doc) catch return;
    _ = out;
}

fn fuzzParseRenderMarkdown(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var doc = zigmark.Parser.init().parseMarkdown(alloc, input) catch return;
    defer doc.deinit(alloc);
    const out = zigmark.MarkdownRenderer.render(alloc, doc) catch return;
    _ = out;
}

fn fuzzFrontmatterYaml(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var fm = zigmark.Frontmatter.init(arena.allocator(), input, .yaml) catch return;
    fm.deinit();
}

fn fuzzFrontmatterToml(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var fm = zigmark.Frontmatter.init(arena.allocator(), input, .toml) catch return;
    fm.deinit();
}

fn fuzzFrontmatterJson(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var fm = zigmark.Frontmatter.init(arena.allocator(), input, .json) catch return;
    fm.deinit();
}
