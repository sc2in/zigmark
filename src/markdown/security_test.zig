//! Security regression tests.
//!
//! Each test here locks in a fix from the production security hardening pass.
//! They run under `std.testing.allocator`, so any leak on an error path (e.g.
//! the nesting/size guards, or a rejected frontmatter parse) fails the test.
const std = @import("std");
const tst = std.testing;
const mem = std.mem;

const AST = @import("ast.zig");
const Parser = @import("parser.zig");
const Frontmatter = @import("frontmatter.zig");
const html = @import("renderers/html.zig");
const typst = @import("renderers/typst.zig");

fn renderHtml(alloc: std.mem.Allocator, src: []const u8, opts: html.Options) ![]u8 {
    var p = Parser.init();
    var doc = try p.parseMarkdown(alloc, src);
    defer doc.deinit(alloc);
    return html.renderWithOptions(alloc, doc, opts);
}

fn renderTypstDoc(alloc: std.mem.Allocator, src: []const u8, opts: typst.DocumentOptions) ![]u8 {
    var p = Parser.init();
    var doc = try p.parseMarkdown(alloc, src);
    defer doc.deinit(alloc);
    return typst.renderDocument(alloc, doc, opts);
}

// ── XSS: URL scheme filtering (default-on) ────────────────────────────────────

test "security: javascript: link href is neutralised" {
    const out = try renderHtml(tst.allocator, "[click](javascript:alert(1))", .{});
    defer tst.allocator.free(out);
    try tst.expect(mem.indexOf(u8, out, "javascript:") == null);
    try tst.expect(mem.indexOf(u8, out, "href=\"\"") != null);
}

test "security: vbscript: and file: are neutralised" {
    inline for (.{ "[x](vbscript:foo)", "[x](file:///etc/passwd)" }) |src| {
        const out = try renderHtml(tst.allocator, src, .{});
        defer tst.allocator.free(out);
        try tst.expect(mem.indexOf(u8, out, "href=\"\"") != null);
    }
}

test "security: entity-obfuscated javascript scheme is caught" {
    const out = try renderHtml(tst.allocator, "[x](java&#115;cript:alert(1))", .{});
    defer tst.allocator.free(out);
    try tst.expect(mem.indexOf(u8, out, "href=\"\"") != null);
}

test "security: non-image data: URI is neutralised" {
    const out = try renderHtml(tst.allocator, "![i](data:text/html,<script>alert(1)</script>)", .{});
    defer tst.allocator.free(out);
    try tst.expect(mem.indexOf(u8, out, "src=\"\"") != null);
    try tst.expect(mem.indexOf(u8, out, "data:text/html") == null);
}

test "security: image data: URI is preserved" {
    const out = try renderHtml(tst.allocator, "![i](data:image/png;base64,iVBORw0KGgo=)", .{});
    defer tst.allocator.free(out);
    try tst.expect(mem.indexOf(u8, out, "data:image/png;base64,iVBORw0KGgo=") != null);
}

test "security: unknown but harmless scheme is preserved (spec conformance guard)" {
    // The CommonMark spec's `<made-up-scheme://foo,bar>` example must still pass.
    const out = try renderHtml(tst.allocator, "<made-up-scheme://foo,bar>", .{});
    defer tst.allocator.free(out);
    try tst.expect(mem.indexOf(u8, out, "made-up-scheme://foo,bar") != null);
}

test "security: ordinary and relative URLs are untouched" {
    const out = try renderHtml(tst.allocator, "[a](https://example.com) [b](/rel/path) [c](#frag)", .{});
    defer tst.allocator.free(out);
    try tst.expect(mem.indexOf(u8, out, "href=\"https://example.com\"") != null);
    try tst.expect(mem.indexOf(u8, out, "href=\"/rel/path\"") != null);
    try tst.expect(mem.indexOf(u8, out, "href=\"#frag\"") != null);
}

// ── XSS: footnote label injection ─────────────────────────────────────────────

test "security: footnote label is escaped in attribute and text" {
    // The label carries no internal whitespace, so under the relaxed label
    // charset (0.11.0) the `[^…]: note` line now parses as a real footnote
    // *definition* rather than a paragraph.  Both the reference site and the
    // definition div embed the label; assert neither leaks a raw tag.
    const src = "x[^a\"><img/onerror=alert(1)>]\n\n[^a\"><img/onerror=alert(1)>]: note\n";
    const out = try renderHtml(tst.allocator, src, .{});
    defer tst.allocator.free(out);
    // No unescaped attribute-breaking quote or raw tag from the label.
    try tst.expect(mem.indexOf(u8, out, "<img/onerror") == null);
    try tst.expect(mem.indexOf(u8, out, "&quot;") != null);
    // The definition path is now exercised: a footnote div is emitted, and its
    // escaped label appears in both the id attribute and the bold marker.
    try tst.expect(mem.indexOf(u8, out, "<div class=\"footnote\" id=\"fn:") != null);
    try tst.expect(mem.indexOf(u8, out, "&lt;img/onerror") != null);
}

// ── XSS: opt-in safe mode escapes raw HTML ────────────────────────────────────

test "security: safe mode escapes raw block HTML" {
    const src = "<div onclick=\"evil()\">hi</div>";
    const safe = try renderHtml(tst.allocator, src, .{ .safe = true });
    defer tst.allocator.free(safe);
    try tst.expect(mem.indexOf(u8, safe, "&lt;div") != null);
    try tst.expect(mem.indexOf(u8, safe, "<div") == null);
}

test "security: safe mode escapes raw inline HTML" {
    const src = "a <b onmouseover=x> c";
    const safe = try renderHtml(tst.allocator, src, .{ .safe = true });
    defer tst.allocator.free(safe);
    try tst.expect(mem.indexOf(u8, safe, "&lt;b onmouseover") != null);
}

test "security: default mode leaves raw HTML output byte-identical" {
    // Default (unsafe) output must not change — preserves CommonMark conformance.
    const src = "<div>hi</div>";
    const out = try renderHtml(tst.allocator, src, .{});
    defer tst.allocator.free(out);
    try tst.expect(mem.indexOf(u8, out, "<div>hi</div>") != null);
}

// ── Panic: ATX heading counter overflow ───────────────────────────────────────

test "security: 300 leading '#' does not panic" {
    var buf: [304]u8 = undefined;
    @memset(buf[0..300], '#');
    buf[300] = ' ';
    buf[301] = 'x';
    const out = try renderHtml(tst.allocator, buf[0..302], .{});
    defer tst.allocator.free(out);
    // Not a heading (>6 hashes) — just make sure we got here without a panic.
    try tst.expect(out.len > 0);
}

// ── DoS: nesting depth guard (no stack overflow, no leak) ─────────────────────

test "security: deep blockquote nesting returns NestingTooDeep" {
    var p = Parser.init();
    p.max_nesting_depth = 8;
    var buf: [64]u8 = undefined;
    @memset(buf[0..40], '>');
    buf[40] = ' ';
    buf[41] = 'x';
    try tst.expectError(error.NestingTooDeep, p.parseMarkdown(tst.allocator, buf[0..42]));
}

test "security: deep list nesting returns NestingTooDeep" {
    var p = Parser.init();
    p.max_nesting_depth = 6;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(tst.allocator);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        try out.appendNTimes(tst.allocator, ' ', i * 2);
        try out.appendSlice(tst.allocator, "- x\n");
    }
    try tst.expectError(error.NestingTooDeep, p.parseMarkdown(tst.allocator, out.items));
}

test "security: deep inline link nesting returns NestingTooDeep" {
    var p = Parser.init();
    p.max_nesting_depth = 1000; // isolate the inline cap
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(tst.allocator);
    const n = 400;
    try out.appendNTimes(tst.allocator, '[', n);
    try out.append(tst.allocator, 'x');
    var i: usize = 0;
    while (i < n) : (i += 1) try out.appendSlice(tst.allocator, "](u)");
    try tst.expectError(error.NestingTooDeep, p.parseMarkdown(tst.allocator, out.items));
}

// ── DoS: input size cap ───────────────────────────────────────────────────────

test "security: oversized input returns InputTooLarge" {
    var p = Parser.init();
    p.max_input_bytes = 64;
    const big = "a" ** 128;
    try tst.expectError(error.InputTooLarge, p.parseMarkdown(tst.allocator, big));
}

test "security: input size cap of 0 disables the limit" {
    var p = Parser.init();
    p.max_input_bytes = 0;
    const src = "hello world";
    var doc = try p.parseMarkdown(tst.allocator, src);
    doc.deinit(tst.allocator);
}

// ── Typst code-injection ──────────────────────────────────────────────────────

test "security: typst code span uses raw() and escapes content" {
    const out = try renderTypstDoc(tst.allocator, "`a`b`", .{});
    defer tst.allocator.free(out);
    try tst.expect(mem.indexOf(u8, out, "#raw(") != null);
}

test "security: typst fenced block cannot break out" {
    const src = "````\n```\n#read(\"/etc/passwd\")\n````";
    const out = try renderTypstDoc(tst.allocator, src, .{});
    defer tst.allocator.free(out);
    // The #read must sit inside a raw() string literal, not as bare markup.
    try tst.expect(mem.indexOf(u8, out, "#raw(block: true") != null);
    try tst.expect(mem.indexOf(u8, out, "#read(\\\"/etc/passwd\\\")") != null);
}

// ── Typst preamble field validation ───────────────────────────────────────────

test "security: malicious fontsize falls back to default" {
    const out = try renderTypstDoc(tst.allocator, "hi", .{
        .fontsize = "1pt); #read(\"/etc/passwd\"); text(size:(1pt",
    });
    defer tst.allocator.free(out);
    try tst.expect(mem.indexOf(u8, out, "#read") == null);
    try tst.expect(mem.indexOf(u8, out, "size: 11pt") != null);
}

test "security: malicious link colour falls back to default" {
    const out = try renderTypstDoc(tst.allocator, "hi", .{
        .colorlinks = true,
        .linkcolor = "000\"); #read(\"/etc/passwd\"); rgb(\"#000",
    });
    defer tst.allocator.free(out);
    try tst.expect(mem.indexOf(u8, out, "#read") == null);
    try tst.expect(mem.indexOf(u8, out, "rgb(\"#A50000\")") != null);
}

test "security: valid fontsize and colour pass through" {
    const out = try renderTypstDoc(tst.allocator, "hi", .{ .fontsize = "12pt", .colorlinks = true, .linkcolor = "abc123" });
    defer tst.allocator.free(out);
    try tst.expect(mem.indexOf(u8, out, "size: 12pt") != null);
    try tst.expect(mem.indexOf(u8, out, "rgb(\"#abc123\")") != null);
}

// ── Frontmatter robustness ────────────────────────────────────────────────────

test "security: large frontmatter integer does not panic" {
    const src = "---\ntoc-depth: 999999999999\n---\n\nbody\n";
    var fm = Frontmatter.initFromMarkdown(tst.allocator, src) catch return; // parse-only; no panic
    fm.deinit();
}

test "security: malformed YAML frontmatter fails cleanly without leaking (#73)" {
    // Genuinely malformed YAML (an unclosed flow sequence) must fail with
    // ParseFailure, and the failure path must free the parser's error bundle —
    // testing.allocator would flag a leak otherwise. (The original repro used
    // `author: Foo - Bar Baz`, but that is a *valid* plain scalar that only
    // failed due to the issue #81 bug; it now parses, so a real malformed
    // input is used here.)
    const src = "---\ntags: [a, b\n---\n\nbody\n";
    try tst.expectError(error.ParseFailure, Frontmatter.initFromMarkdown(tst.allocator, src));
}
