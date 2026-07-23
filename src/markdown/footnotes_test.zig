//! Tests for programmatic footnote synthesis (`footnotes.zig`).
//!
//! All tests run under `std.testing.allocator`, so any leak — including on the
//! resolver-error path — fails the test.
const std = @import("std");
const tst = std.testing;
const mem = std.mem;
const Allocator = std.mem.Allocator;

const AST = @import("ast.zig");
const Parser = @import("parser.zig");
const footnotes = @import("footnotes.zig");
const html = @import("renderers/html.zig");
const typst = @import("renderers/typst.zig");
const md_renderer = @import("renderers/markdown.zig");

// ── Test resolvers ────────────────────────────────────────────────────────────

/// Records how many times a resolver was invoked.
const Recorder = struct {
    calls: usize = 0,
};

/// Resolves a small fixed catalog; unknown labels return `null`.
fn resolveCatalog(ctx: ?*anyopaque, allocator: Allocator, label: []const u8) anyerror!?[]const u8 {
    if (ctx) |p| {
        const rec: *Recorder = @ptrCast(@alignCast(p));
        rec.calls += 1;
    }
    if (mem.eql(u8, label, "IAC-01"))
        return try allocator.dupe(u8, "IAC-01 — Identification. Covered by Access Control Policy.");
    if (mem.eql(u8, label, "GOV-01"))
        return try allocator.dupe(u8, "Governance definition body.");
    if (mem.eql(u8, label, "MULTI"))
        return try allocator.dupe(u8, "First paragraph.\n\nSecond paragraph.");
    return null;
}

/// Resolves every label to the same benign body.
fn resolveAny(ctx: ?*anyopaque, allocator: Allocator, label: []const u8) anyerror!?[]const u8 {
    _ = ctx;
    _ = label;
    return try allocator.dupe(u8, "definition body");
}

/// Always fails — exercises the error path.
fn resolveErr(ctx: ?*anyopaque, allocator: Allocator, label: []const u8) anyerror!?[]const u8 {
    _ = ctx;
    _ = allocator;
    _ = label;
    return error.ResolverFailed;
}

fn parse(alloc: Allocator, src: []const u8) !AST.Document {
    var p = Parser.init();
    return p.parseMarkdown(alloc, src);
}

// ── resolve() ─────────────────────────────────────────────────────────────────

test "resolve: synthesizes a definition for a missing reference" {
    const alloc = tst.allocator;
    var doc = try parse(alloc, "See [^IAC-01].\n");
    defer doc.deinit(alloc);

    const report = try footnotes.resolve(alloc, &doc, .{ .resolveFn = resolveCatalog }, .{});
    try tst.expectEqual(@as(usize, 1), report.synthesized);
    try tst.expectEqual(@as(usize, 0), report.unresolved);

    // A footnote_definition for IAC-01 now exists at the top level.
    var found = false;
    for (doc.children.items) |b| {
        if (b == .footnote_definition and mem.eql(u8, b.footnote_definition.label, "IAC-01")) found = true;
    }
    try tst.expect(found);
}

test "resolve: existing definition is untouched and resolver is not called" {
    const alloc = tst.allocator;
    var doc = try parse(alloc, "See [^IAC-01].\n\n[^IAC-01]: already defined\n");
    defer doc.deinit(alloc);

    var rec = Recorder{};
    const report = try footnotes.resolve(alloc, &doc, .{ .ctx = &rec, .resolveFn = resolveCatalog }, .{});
    try tst.expectEqual(@as(usize, 0), report.synthesized);
    try tst.expectEqual(@as(usize, 0), report.unresolved);
    try tst.expectEqual(@as(usize, 0), rec.calls);
}

test "resolve: repeated references are deduplicated (one synthesis)" {
    const alloc = tst.allocator;
    var doc = try parse(alloc, "[^IAC-01] and again [^IAC-01].\n");
    defer doc.deinit(alloc);

    var rec = Recorder{};
    const report = try footnotes.resolve(alloc, &doc, .{ .ctx = &rec, .resolveFn = resolveCatalog }, .{});
    try tst.expectEqual(@as(usize, 1), report.synthesized);
    try tst.expectEqual(@as(usize, 1), rec.calls);
}

test "resolve: definitions are appended in first-reference order" {
    const alloc = tst.allocator;
    var doc = try parse(alloc, "[^GOV-01] then [^IAC-01].\n");
    defer doc.deinit(alloc);

    const report = try footnotes.resolve(alloc, &doc, .{ .resolveFn = resolveCatalog }, .{});
    try tst.expectEqual(@as(usize, 2), report.synthesized);

    const n = doc.children.items.len;
    try tst.expect(n >= 3);
    // The paragraph is first; the two synthesised defs follow in ref order.
    try tst.expect(doc.children.items[n - 2] == .footnote_definition);
    try tst.expect(doc.children.items[n - 1] == .footnote_definition);
    try tst.expectEqualStrings("GOV-01", doc.children.items[n - 2].footnote_definition.label);
    try tst.expectEqualStrings("IAC-01", doc.children.items[n - 1].footnote_definition.label);
}

test "resolve: null result counts as unresolved" {
    const alloc = tst.allocator;
    var doc = try parse(alloc, "[^UNKNOWN] and [^IAC-01].\n");
    defer doc.deinit(alloc);

    const report = try footnotes.resolve(alloc, &doc, .{ .resolveFn = resolveCatalog }, .{});
    try tst.expectEqual(@as(usize, 1), report.synthesized);
    try tst.expectEqual(@as(usize, 1), report.unresolved);
}

test "resolve: multi-block resolver content becomes multiple child blocks" {
    const alloc = tst.allocator;
    var doc = try parse(alloc, "[^MULTI]\n");
    defer doc.deinit(alloc);

    const report = try footnotes.resolve(alloc, &doc, .{ .resolveFn = resolveCatalog }, .{});
    try tst.expectEqual(@as(usize, 1), report.synthesized);

    const n = doc.children.items.len;
    const def = doc.children.items[n - 1].footnote_definition;
    try tst.expectEqual(@as(usize, 2), def.children.items.len);
    try tst.expect(def.children.items[0] == .paragraph);
    try tst.expect(def.children.items[1] == .paragraph);
}

test "resolve: references inside blockquotes and table cells are found" {
    const alloc = tst.allocator;
    const src =
        \\> A quote referencing [^GOV-01].
        \\
        \\| Column [^IAC-01] |
        \\|---|
        \\| cell |
    ;
    var doc = try parse(alloc, src);
    defer doc.deinit(alloc);

    const report = try footnotes.resolve(alloc, &doc, .{ .resolveFn = resolveCatalog }, .{});
    try tst.expectEqual(@as(usize, 2), report.synthesized);
}

test "resolve: no leak when the resolver errors" {
    const alloc = tst.allocator;
    var doc = try parse(alloc, "[^IAC-01]\n");
    defer doc.deinit(alloc);

    try tst.expectError(
        error.ResolverFailed,
        footnotes.resolve(alloc, &doc, .{ .resolveFn = resolveErr }, .{}),
    );
}

// ── End-to-end rendering ────────────────────────────────────────────────────────

test "resolve then HTML: reference links to synthesised definition div" {
    const alloc = tst.allocator;
    var doc = try parse(alloc, "See [^IAC-01].\n");
    defer doc.deinit(alloc);

    _ = try footnotes.resolve(alloc, &doc, .{ .resolveFn = resolveCatalog }, .{});

    const out = try html.render(alloc, doc);
    defer alloc.free(out);
    try tst.expect(mem.indexOf(u8, out, "href=\"#fn:IAC-01\"") != null);
    try tst.expect(mem.indexOf(u8, out, "<div class=\"footnote\" id=\"fn:IAC-01\">") != null);
    try tst.expect(mem.indexOf(u8, out, "Identification") != null);
}

test "resolve then Typst: reference expands to a native footnote (no placeholder)" {
    const alloc = tst.allocator;
    var doc = try parse(alloc, "See [^IAC-01].\n");
    defer doc.deinit(alloc);

    _ = try footnotes.resolve(alloc, &doc, .{ .resolveFn = resolveCatalog }, .{});

    const out = try typst.render(alloc, doc);
    defer alloc.free(out);
    // Native Typst footnote, expanded from the synthesised definition body
    // (not the bare-label placeholder used for undefined references).
    try tst.expect(mem.indexOf(u8, out, "#footnote[") != null);
    try tst.expect(mem.indexOf(u8, out, "Identification") != null);
}

test "resolve then Markdown: synthesised definition round-trips" {
    const alloc = tst.allocator;
    var doc = try parse(alloc, "See [^IAC-01].\n");
    defer doc.deinit(alloc);

    _ = try footnotes.resolve(alloc, &doc, .{ .resolveFn = resolveCatalog }, .{});

    const out = try md_renderer.render(alloc, doc);
    defer alloc.free(out);
    try tst.expect(mem.indexOf(u8, out, "[^IAC-01]") != null);
    try tst.expect(mem.indexOf(u8, out, "[^IAC-01]: ") != null);
}

test "resolve then HTML: hostile label from synthesis path is escaped" {
    const alloc = tst.allocator;
    var doc = try parse(alloc, "Danger [^<img src=x onerror=alert(1)>].\n");
    defer doc.deinit(alloc);

    // resolveAny returns a definition for the hostile label, so it is
    // synthesised — exercising label escaping through the definition path.
    const report = try footnotes.resolve(alloc, &doc, .{ .resolveFn = resolveAny }, .{});
    try tst.expectEqual(@as(usize, 1), report.synthesized);

    const out = try html.render(alloc, doc);
    defer alloc.free(out);
    try tst.expect(mem.indexOf(u8, out, "<img src=x") == null);
    try tst.expect(mem.indexOf(u8, out, "&lt;img src=x") != null);
}

// ── dangling() ──────────────────────────────────────────────────────────────────

test "dangling: lists undefined references, deduped, in first-ref order" {
    const alloc = tst.allocator;
    var doc = try parse(alloc, "[^B] then [^A] then [^A] then [^C].\n\n[^C]: defined\n");
    defer doc.deinit(alloc);

    const missing = try footnotes.dangling(alloc, &doc);
    defer {
        for (missing) |m| alloc.free(m);
        alloc.free(missing);
    }
    // C is defined; B and A remain, in first-reference order, deduped.
    try tst.expectEqual(@as(usize, 2), missing.len);
    try tst.expectEqualStrings("B", missing[0]);
    try tst.expectEqualStrings("A", missing[1]);
}

test "dangling: catches references introduced by synthesised content (single pass)" {
    const alloc = tst.allocator;
    // The resolver body itself references [^IAC-01], which resolve() does not
    // recurse into; dangling() surfaces it afterwards.
    const Local = struct {
        fn resolveNested(ctx: ?*anyopaque, allocator: Allocator, label: []const u8) anyerror!?[]const u8 {
            _ = ctx;
            if (mem.eql(u8, label, "GOV-01"))
                return try allocator.dupe(u8, "Governance — see [^IAC-01] for identity.");
            return null;
        }
    };

    var doc = try parse(alloc, "[^GOV-01]\n");
    defer doc.deinit(alloc);

    const report = try footnotes.resolve(alloc, &doc, .{ .resolveFn = Local.resolveNested }, .{});
    try tst.expectEqual(@as(usize, 1), report.synthesized);

    const missing = try footnotes.dangling(alloc, &doc);
    defer {
        for (missing) |m| alloc.free(m);
        alloc.free(missing);
    }
    try tst.expectEqual(@as(usize, 1), missing.len);
    try tst.expectEqualStrings("IAC-01", missing[0]);
}
