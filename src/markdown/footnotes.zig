//! Programmatic footnote synthesis.
//!
//! A document may *reference* footnotes (`[^label]`) that have no matching
//! `[^label]: …` definition — for example when the definition text lives in an
//! external data source (a control catalog, a glossary, a database).  This
//! module lets a caller supply those definitions on demand through a
//! `Resolver` callback and have them synthesised into the AST as real
//! `footnote_definition` blocks.
//!
//! Because synthesis happens at the **AST level** (not in a renderer), every
//! back-end benefits with zero renderer changes:
//!
//!   * the Typst renderer's existing footnote pre-pass turns the now-defined
//!     references into native `#footnote[…]` (PDF/UA-1-friendly);
//!   * the HTML renderer links references to the appended definition divs; and
//!   * the Markdown renderer round-trips the synthesised `[^label]: …` lines.
//!
//! ## Usage
//!
//! ```zig
//! const report = try footnotes.resolve(allocator, &doc, resolver, .{});
//! // report.synthesized — definitions added; report.unresolved — refs the
//! // resolver returned null for. Use footnotes.dangling() to list the latter.
//! ```
//!
//! `resolve` is **single-pass**: footnote references that appear *inside*
//! resolver-returned content are not themselves resolved.  Call `dangling`
//! afterwards to discover any such (or otherwise unknown) labels — consumers
//! typically hard-fail a build on a non-empty result.
const std = @import("std");
const Allocator = std.mem.Allocator;

const AST = @import("ast.zig");
const Parser = @import("parser.zig");

/// Supplies Markdown source for footnote definitions on demand.
pub const Resolver = struct {
    /// Opaque context threaded to `resolveFn` (e.g. a `*const Library`).
    ctx: ?*anyopaque = null,
    /// Return Markdown source for `label`'s definition body, or `null` when the
    /// label is unknown.  A non-null result must be allocated with the passed
    /// `allocator`; zigmark frees it (the `MermaidRendererFn` ownership
    /// contract).  The returned Markdown may contain multiple blocks.
    resolveFn: *const fn (ctx: ?*anyopaque, allocator: Allocator, label: []const u8) anyerror!?[]const u8,

    fn call(self: Resolver, allocator: Allocator, label: []const u8) anyerror!?[]const u8 {
        return self.resolveFn(self.ctx, allocator, label);
    }
};

/// Options controlling `resolve`.
pub const ResolveOptions = struct {
    /// Parser used to turn resolver-returned Markdown into AST blocks.  Defaults
    /// to a plain parser; pass one with matching flags (e.g. `.math = true`) so
    /// synthesised definitions parse the same way as the host document.
    parser: Parser = .{},
};

/// Outcome of a `resolve` call.
pub const ResolveReport = struct {
    /// Number of footnote definitions synthesised and appended to the document.
    synthesized: usize = 0,
    /// Number of undefined references the resolver returned `null` for.
    unresolved: usize = 0,
};

/// Synthesise definitions for every undefined footnote reference in `doc`.
///
/// For each *distinct* referenced label (in first-reference order) that lacks a
/// top-level `footnote_definition`, the `resolver` is invoked.  A non-null
/// result is parsed and appended to `doc` as a new `footnote_definition` block;
/// a `null` result increments `unresolved`.
///
/// Definitions are only ever top-level in `doc.children`, so only that level is
/// scanned for existing definitions and that is where synthesised blocks land.
pub fn resolve(
    allocator: Allocator,
    doc: *AST.Document,
    resolver: Resolver,
    opts: ResolveOptions,
) !ResolveReport {
    var report = ResolveReport{};

    // Existing top-level definitions — never re-synthesise these.
    var defined = std.StringHashMap(void).init(allocator);
    defer defined.deinit();
    for (doc.children.items) |*block| {
        if (block.* == .footnote_definition)
            try defined.put(block.footnote_definition.label, {});
    }

    // Referenced labels in first-reference order, deduplicated.  The label
    // slices borrow from the documents' inline-source buffers, which are not
    // moved by appending blocks below, so they stay valid across the mutation.
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var ordered = std.ArrayList([]const u8).empty;
    defer ordered.deinit(allocator);
    for (doc.children.items) |*block| try walkBlockRefs(block, &seen, &ordered, allocator);

    for (ordered.items) |label| {
        if (defined.contains(label)) continue;
        const md = try resolver.call(allocator, label) orelse {
            report.unresolved += 1;
            continue;
        };
        defer allocator.free(md);

        var fn_def = try synthesizeDefinition(allocator, opts.parser, label, md);
        doc.edit().appendBlock(allocator, .{ .footnote_definition = fn_def }) catch |err| {
            fn_def.deinit(allocator);
            return err;
        };
        report.synthesized += 1;
    }

    return report;
}

/// Return the deduplicated labels of every footnote reference in `doc` that has
/// no matching top-level definition, in first-reference order.
///
/// The returned slice and each label are owned by the caller: free every entry
/// and then the slice with the same allocator.
pub fn dangling(allocator: Allocator, doc: *const AST.Document) ![][]const u8 {
    var defined = std.StringHashMap(void).init(allocator);
    defer defined.deinit();
    for (doc.children.items) |*block| {
        if (block.* == .footnote_definition)
            try defined.put(block.footnote_definition.label, {});
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var ordered = std.ArrayList([]const u8).empty;
    defer ordered.deinit(allocator);
    for (doc.children.items) |*block| try walkBlockRefs(block, &seen, &ordered, allocator);

    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    for (ordered.items) |label| {
        if (defined.contains(label)) continue;
        const owned = try allocator.dupe(u8, label);
        errdefer allocator.free(owned);
        try out.append(allocator, owned);
    }
    return out.toOwnedSlice(allocator);
}

// ── Internal ──────────────────────────────────────────────────────────────────

/// Parse `markdown` (a resolver's definition body) and build a
/// `FootnoteDefinition` for `label` that OWNS the parsed blocks.
///
/// The parsed blocks are **moved** out of the temporary document; only the
/// document's list shell is freed here.  Calling `tmp.deinit` would double-free
/// the moved blocks, so it is never called.  The label is duped — definitions
/// own their labels (see `AST.FootnoteDefinition.deinit`).
fn synthesizeDefinition(
    allocator: Allocator,
    parser: Parser,
    label: []const u8,
    markdown: []const u8,
) !AST.FootnoteDefinition {
    var tmp = try parser.parseMarkdown(allocator, markdown);
    // While `tmp` still owns the blocks, any failure must free it in full.
    var moved = false;
    errdefer if (!moved) tmp.deinit(allocator);

    const owned_label = try allocator.dupe(u8, label);
    var fn_def = AST.FootnoteDefinition.init(allocator, owned_label);
    // Past here `fn_def` owns the label (and, once moved, the blocks); a failure
    // frees it and only `tmp`'s list shell.
    errdefer fn_def.deinit(allocator);

    // Reserve up-front so the moves below cannot fail (all-or-nothing transfer).
    try fn_def.children.ensureTotalCapacity(allocator, tmp.children.items.len);
    for (tmp.children.items) |block| fn_def.children.appendAssumeCapacity(block);

    // Ownership transferred; free only the now-logically-empty list shell.
    moved = true;
    tmp.children.deinit(allocator);

    return fn_def;
}

fn walkBlockRefs(
    block: *const AST.Block,
    seen: *std.StringHashMap(void),
    ordered: *std.ArrayList([]const u8),
    allocator: Allocator,
) Allocator.Error!void {
    switch (block.*) {
        .paragraph => |*p| try walkInlineRefs(p.children.items, seen, ordered, allocator),
        .heading => |*h| try walkInlineRefs(h.children.items, seen, ordered, allocator),
        .blockquote => |*bq| for (bq.children.items) |*b| try walkBlockRefs(b, seen, ordered, allocator),
        .list => |*l| for (l.items.items) |*item| {
            for (item.children.items) |*b| try walkBlockRefs(b, seen, ordered, allocator);
        },
        .footnote_definition => |*fd| for (fd.children.items) |*b| try walkBlockRefs(b, seen, ordered, allocator),
        .table => |*t| {
            for (t.header.cells.items) |*c| try walkInlineRefs(c.children.items, seen, ordered, allocator);
            for (t.body.items) |*row| {
                for (row.cells.items) |*c| try walkInlineRefs(c.children.items, seen, ordered, allocator);
            }
        },
        else => {},
    }
}

fn walkInlineRefs(
    inlines: []const AST.Inline,
    seen: *std.StringHashMap(void),
    ordered: *std.ArrayList([]const u8),
    allocator: Allocator,
) Allocator.Error!void {
    for (inlines) |*inl| switch (inl.*) {
        .footnote_reference => |fr| {
            const gop = try seen.getOrPut(fr.label);
            if (!gop.found_existing) try ordered.append(allocator, fr.label);
        },
        .emphasis => |*e| try walkInlineRefs(e.children.items, seen, ordered, allocator),
        .strong => |*s| try walkInlineRefs(s.children.items, seen, ordered, allocator),
        .strikethrough => |*s| try walkInlineRefs(s.children.items, seen, ordered, allocator),
        .link => |*l| try walkInlineRefs(l.children.items, seen, ordered, allocator),
        else => {},
    };
}
