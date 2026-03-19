const std = @import("std");
const tst = std.testing;

const Library = @import("library.zig").Library;

// ── helpers ──────────────────────────────────────────────────────────────────

const policy_a =
    \\---
    \\title: "Access Control Policy"
    \\extra:
    \\  owner: SC2
    \\  category: security
    \\taxonomies:
    \\  SCF:
    \\    - IAC-01
    \\    - IAC-02
    \\---
    \\
    \\## Purpose
    \\
    \\This policy defines access control requirements.
    \\
    \\```zig
    \\const x = 1;
    \\```
;

const policy_b =
    \\---
    \\title: "HR Policy"
    \\extra:
    \\  owner: HR
    \\  category: hr
    \\taxonomies:
    \\  SCF:
    \\    - HRS-05
    \\---
    \\
    \\## Scope
    \\
    \\All employees are subject to this policy.
    \\
    \\## Responsibilities
    \\
    \\Management must enforce this policy.
;

const no_frontmatter =
    \\# Plain Document
    \\
    \\No frontmatter here.
;

// ── lifecycle ─────────────────────────────────────────────────────────────────

test "library: init and deinit empty" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();
    try tst.expectEqual(@as(usize, 0), lib.entries.items.len);
}

test "library: add documents" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, "policies/access-control.md");
    try lib.add(policy_b, "policies/hr.md");
    try lib.add(no_frontmatter, null);

    try tst.expectEqual(@as(usize, 3), lib.entries.items.len);
}

test "library: entry path is copied" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, "policies/access-control.md");
    try tst.expectEqualStrings("policies/access-control.md", lib.entries.items[0].path.?);
}

test "library: entry without path" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null);
    try tst.expect(lib.entries.items[0].path == null);
}

test "library: document without frontmatter has null frontmatter" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(no_frontmatter, null);
    try tst.expect(lib.entries.items[0].frontmatter == null);
}

test "library: document with frontmatter has parsed frontmatter" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null);
    const fm = lib.entries.items[0].frontmatter orelse return error.MissingFrontmatter;
    const title = fm.get("title") orelse return error.MissingTitle;
    try tst.expectEqualStrings("Access Control Policy", title.string);
}

// ── query: no results ─────────────────────────────────────────────────────────

test "library: query on empty library returns null" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    const results = try lib.query(tst.allocator, "title");
    try tst.expect(results == null);
}

test "library: query no match returns null" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null);
    try lib.add(policy_b, null);

    const results = try lib.query(tst.allocator, "extra.owner=nobody");
    try tst.expect(results == null);
}

// ── query: frontmatter filters ────────────────────────────────────────────────

test "library: query field exists" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null);
    try lib.add(policy_b, null);
    try lib.add(no_frontmatter, null);

    const results = try lib.query(tst.allocator, "title");
    defer tst.allocator.free(results.?);

    // Only the two docs with frontmatter match.
    try tst.expectEqual(@as(usize, 2), results.?.len);
    try tst.expectEqual(@as(f32, 1.0), results.?[0].confidence);
}

test "library: query field equals value" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null);
    try lib.add(policy_b, null);

    const results = try lib.query(tst.allocator, "extra.owner=SC2");
    defer tst.allocator.free(results.?);

    try tst.expectEqual(@as(usize, 1), results.?.len);
    try tst.expect(results.?[0].block == null); // doc-level result
    try tst.expectEqual(@as(f32, 1.0), results.?[0].confidence);
}

test "library: query nested dot path" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null);
    try lib.add(policy_b, null);

    const results = try lib.query(tst.allocator, "extra.category=hr");
    defer tst.allocator.free(results.?);

    try tst.expectEqual(@as(usize, 1), results.?.len);
}

test "library: query field exists excludes docs without frontmatter" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(no_frontmatter, null);

    const results = try lib.query(tst.allocator, "title");
    try tst.expect(results == null);
}

// ── query: block selection ────────────────────────────────────────────────────

test "library: query @heading returns all headings across all docs" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null); // 1 heading: "Purpose"
    try lib.add(policy_b, null); // 2 headings: "Scope", "Responsibilities"

    const results = try lib.query(tst.allocator, "@heading");
    defer tst.allocator.free(results.?);

    try tst.expectEqual(@as(usize, 3), results.?.len);
    for (results.?) |r| {
        try tst.expect(r.block != null);
        try tst.expect(r.block.?.* == .heading);
    }
}

test "library: query fm filter + @heading" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null); // 1 heading
    try lib.add(policy_b, null); // 2 headings
    try lib.add(no_frontmatter, null); // 1 heading but no frontmatter

    const results = try lib.query(tst.allocator, "extra.owner=SC2 @heading");
    defer tst.allocator.free(results.?);

    // Only policy_a matches the fm filter.
    try tst.expectEqual(@as(usize, 1), results.?.len);
    try tst.expect(results.?[0].block.?.* == .heading);
}

test "library: query @fenced_code_block" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null); // has a fenced code block
    try lib.add(policy_b, null); // no code blocks

    const results = try lib.query(tst.allocator, "@fenced_code_block");
    defer tst.allocator.free(results.?);

    try tst.expectEqual(@as(usize, 1), results.?.len);
    try tst.expect(results.?[0].block.?.* == .fenced_code_block);
    try tst.expectEqualStrings("zig", results.?[0].block.?.fenced_code_block.language.?);
}

test "library: query unknown block tag returns null" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null);

    // "@unknown_type" won't match any tag → no blocks selected → no results.
    const results = try lib.query(tst.allocator, "@unknown_type");
    try tst.expect(results == null);
}

// ── query: no filter (wildcard) ───────────────────────────────────────────────

test "library: query empty string returns all docs" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null);
    try lib.add(policy_b, null);
    try lib.add(no_frontmatter, null);

    const results = try lib.query(tst.allocator, "");
    defer tst.allocator.free(results.?);

    try tst.expectEqual(@as(usize, 3), results.?.len);
}

// ── query: result ordering ────────────────────────────────────────────────────

test "library: results sorted by confidence descending" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null);
    try lib.add(policy_b, null);

    const results = try lib.query(tst.allocator, "title");
    defer tst.allocator.free(results.?);

    for (results.?[0 .. results.?.len - 1], results.?[1..]) |a, b| {
        try tst.expect(a.confidence >= b.confidence);
    }
}

// ── regression: array containment matching ───────────────────────────────────
//
// Bug: jsonValueMatchesString returned false for .array values, so querying
// a taxonomy field like `taxonomies.SCF=HRS-05` always returned null even
// when "HRS-05" was an element of the array.

const policy_with_taxonomies =
    \\---
    \\title: "HR Policy"
    \\taxonomies:
    \\  SCF:
    \\    - HRS-05
    \\    - HRS-05.1
    \\    - HRS-05.2
    \\  TSC2017:
    \\    - CC2.1
    \\    - P4.1
    \\---
    \\
    \\## Scope
    \\
    \\All employees.
;

test "regression: array field containment — first element matches" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_with_taxonomies, null);

    const results = try lib.query(tst.allocator, "taxonomies.SCF=HRS-05");
    defer tst.allocator.free(results.?);

    try tst.expectEqual(@as(usize, 1), results.?.len);
    try tst.expectEqual(@as(f32, 1.0), results.?[0].confidence);
}

test "regression: array field containment — mid-array element matches" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_with_taxonomies, null);

    const results = try lib.query(tst.allocator, "taxonomies.SCF=HRS-05.2");
    defer tst.allocator.free(results.?);

    try tst.expectEqual(@as(usize, 1), results.?.len);
}

test "regression: array field containment — absent value returns null" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_with_taxonomies, null);

    const results = try lib.query(tst.allocator, "taxonomies.SCF=NOT-THERE");
    try tst.expect(results == null);
}

test "regression: array field containment — multiple docs, selective match" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_with_taxonomies, "hr.md");
    try lib.add(policy_a, "access.md"); // has taxonomies.SCF: [IAC-01, IAC-02]

    // Only hr.md has HRS-05 in its SCF array.
    const results = try lib.query(tst.allocator, "taxonomies.SCF=HRS-05");
    defer tst.allocator.free(results.?);

    try tst.expectEqual(@as(usize, 1), results.?.len);
    try tst.expectEqualStrings("hr.md", results.?[0].entry.path.?);
}

test "regression: array field containment — different taxonomy key" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_with_taxonomies, null);

    const results = try lib.query(tst.allocator, "taxonomies.TSC2017=CC2.1");
    defer tst.allocator.free(results.?);

    try tst.expectEqual(@as(usize, 1), results.?.len);
}

// ── regression: recursive block traversal ────────────────────────────────────
//
// Bug: executeQuery only iterated entry.document.children.items (top-level
// blocks).  Paragraphs inside blockquotes or list items were invisible.

const nested_content =
    \\# Top heading
    \\
    \\> ## Blockquote heading
    \\>
    \\> Paragraph inside blockquote.
    \\
    \\- List item one
    \\
    \\  Paragraph inside list item.
    \\
    \\- List item two
;

test "regression: recursive traversal — paragraph inside blockquote found" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(nested_content, null);

    const results = try lib.query(tst.allocator, "@paragraph");
    defer tst.allocator.free(results.?);

    // "Paragraph inside blockquote." and "Paragraph inside list item."
    // were previously invisible; there should be at least 2 paragraphs.
    try tst.expect(results.?.len >= 2);
    for (results.?) |r| try tst.expect(r.block.?.* == .paragraph);
}

test "regression: recursive traversal — heading inside blockquote found" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(nested_content, null);

    const results = try lib.query(tst.allocator, "@heading");
    defer tst.allocator.free(results.?);

    // Top-level h1 + h2 inside the blockquote.
    try tst.expect(results.?.len >= 2);
}

test "regression: recursive traversal — top-level blocks still returned" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    // policy_a has one top-level heading and one top-level fenced code block.
    try lib.add(policy_a, null);

    const headings = try lib.query(tst.allocator, "@heading");
    defer tst.allocator.free(headings.?);
    try tst.expectEqual(@as(usize, 1), headings.?.len);
    try tst.expectEqual(@as(u8, 2), headings.?[0].block.?.heading.level);
}

// ── content_hash ──────────────────────────────────────────────────────────────

test "library: same source produces same hash" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null);
    try lib.add(policy_a, null);

    try tst.expectEqual(lib.entries.items[0].content_hash, lib.entries.items[1].content_hash);
}

test "library: different source produces different hash" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null);
    try lib.add(policy_b, null);

    try tst.expect(lib.entries.items[0].content_hash != lib.entries.items[1].content_hash);
}

// ── query: multiple frontmatter filters ───────────────────────────────────────

test "library: multiple fm filters AND semantics" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null); // extra.owner=SC2, extra.category=security
    try lib.add(policy_b, null); // extra.owner=HR,  extra.category=hr

    const results = try lib.query(tst.allocator, "extra.owner=SC2 extra.category=security");
    defer tst.allocator.free(results.?);

    try tst.expectEqual(@as(usize, 1), results.?.len);
    try tst.expectEqualStrings("Access Control Policy",
        results.?[0].entry.frontmatter.?.get("title").?.string);
}

test "library: multiple fm filters partial match excluded" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    // policy_a has owner=SC2 but category=security, not hr → no match.
    try lib.add(policy_a, null);

    const results = try lib.query(tst.allocator, "extra.owner=SC2 extra.category=hr");
    try tst.expect(results == null);
}

test "library: multiple fm filters exist checks" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null);
    try lib.add(policy_b, null);

    // Both docs have title and extra.owner (any value).
    const results = try lib.query(tst.allocator, "title extra.owner");
    defer tst.allocator.free(results.?);

    try tst.expectEqual(@as(usize, 2), results.?.len);
}

// ── sortBy ────────────────────────────────────────────────────────────────────

test "library: sortBy field ascending" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    // Add in reverse-alpha order so the sort has work to do.
    try lib.add(policy_b, null); // "HR Policy"
    try lib.add(policy_a, null); // "Access Control Policy"

    const results = try lib.query(tst.allocator, "title");
    defer tst.allocator.free(results.?);

    Library.sortBy(results.?, "title", true);

    try tst.expectEqualStrings("Access Control Policy",
        results.?[0].entry.frontmatter.?.get("title").?.string);
    try tst.expectEqualStrings("HR Policy",
        results.?[1].entry.frontmatter.?.get("title").?.string);
}

test "library: sortBy field descending" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(policy_a, null); // "Access Control Policy"
    try lib.add(policy_b, null); // "HR Policy"

    const results = try lib.query(tst.allocator, "title");
    defer tst.allocator.free(results.?);

    Library.sortBy(results.?, "title", false);

    try tst.expectEqualStrings("HR Policy",
        results.?[0].entry.frontmatter.?.get("title").?.string);
    try tst.expectEqualStrings("Access Control Policy",
        results.?[1].entry.frontmatter.?.get("title").?.string);
}

test "library: sortBy missing field sorts last" {
    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.add(no_frontmatter, null); // no title
    try lib.add(policy_a, null);       // "Access Control Policy"

    const results = try lib.query(tst.allocator, "");
    defer tst.allocator.free(results.?);

    Library.sortBy(results.?, "title", true);

    // The doc with a title sorts first; the doc without frontmatter sorts last.
    try tst.expect(results.?[0].entry.frontmatter != null);
    try tst.expect(results.?[1].entry.frontmatter == null);
}

// ── addFromFile ───────────────────────────────────────────────────────────────

test "library: addFromFile parses and stores document" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var f = try tmp.dir.createFile("policy.md", .{});
        defer f.close();
        try f.writeAll(policy_a);
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath("policy.md", &path_buf);

    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.addFromFile(abs);

    try tst.expectEqual(@as(usize, 1), lib.entries.items.len);
    const fm = lib.entries.items[0].frontmatter orelse return error.MissingFrontmatter;
    try tst.expectEqualStrings("Access Control Policy", fm.get("title").?.string);
}

test "library: addFromFile stores path identifier" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var f = try tmp.dir.createFile("policy.md", .{});
        defer f.close();
        try f.writeAll(policy_a);
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath("policy.md", &path_buf);

    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.addFromFile(abs);

    try tst.expectEqualStrings(abs, lib.entries.items[0].path.?);
}

// ── addFromDir ────────────────────────────────────────────────────────────────

test "library: addFromDir loads all md files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var f = try tmp.dir.createFile("a.md", .{});
        defer f.close();
        try f.writeAll(policy_a);
    }
    {
        var f = try tmp.dir.createFile("b.md", .{});
        defer f.close();
        try f.writeAll(policy_b);
    }
    {
        var f = try tmp.dir.createFile("notes.txt", .{}); // should be skipped
        f.close();
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_dir = try tmp.dir.realpath(".", &path_buf);

    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.addFromDir(abs_dir);

    try tst.expectEqual(@as(usize, 2), lib.entries.items.len);
}

test "library: addFromDir recurses into subdirectories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("sub");
    {
        var f = try tmp.dir.createFile("top.md", .{});
        defer f.close();
        try f.writeAll(policy_a);
    }
    {
        var sub = try tmp.dir.openDir("sub", .{});
        defer sub.close();
        var f = try sub.createFile("nested.md", .{});
        defer f.close();
        try f.writeAll(policy_b);
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_dir = try tmp.dir.realpath(".", &path_buf);

    var lib = Library.init(tst.allocator);
    defer lib.deinit();

    try lib.addFromDir(abs_dir);

    try tst.expectEqual(@as(usize, 2), lib.entries.items.len);
}
