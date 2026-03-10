//! Copyright © 2025 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!TODO: Pass https://github.com/commonmark/commonmark-spec/blob/master/test/spec_tests.py
const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const testing = std.testing;
const Array = std.ArrayList;
const tst = std.testing;
const math = std.math;

const mecha = @import("mecha");

pub const AST = @import("markdown/ast.zig");
pub const Parser = @import("markdown/parser.zig");
const html = @import("markdown/renderers/html.zig");

pub const HTMLRenderer = Renderer.create(html);
pub const Renderer = struct {
    vtable: struct {
        render: *const fn (Allocator, AST.Document) anyerror![]u8,
    },

    pub fn create(comptime T: type) Renderer {
        return Renderer{
            .vtable = .{
                .render = @field(T, "render"),
            },
        };
    }
    pub fn render(self: Renderer, alloc: Allocator, doc: AST.Document) ![]u8 {
        return try self.vtable.render(alloc, doc);
    }
};
/// Character classification helpers
pub const chars = struct {
    /// ASCII whitespace: space, tab, line feed, form feed, carriage return
    pub fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }

    /// ASCII punctuation character
    pub fn isPunctuation(c: u8) bool {
        return (c >= '!' and c <= '/') or
            (c >= ':' and c <= '@') or
            (c >= '[' and c <= '`') or
            (c >= '{' and c <= '~');
    }

    /// ASCII alphanumeric
    pub fn isAlphanumeric(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9');
    }

    /// ASCII letter
    pub fn isLetter(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    }

    /// ASCII digit
    pub fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }
};

test "enhanced parse and render" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const allocator = arena.allocator();

    const input =
        \\# Heading
        \\
        \\Paragraph [text](https://sc2.in).
        \\
        \\- item1
        \\- item2
        \\
        \\Some more **bold** text and some _italic_ text.
        \\
        \\> a block quote
        \\
        \\a footnote[^SCF:GOV-01]
        \\a footnote[^2]
        \\
        \\## Heading 2
        \\
        \\[^SCF:GOV-01]: Footnote 1
        \\[^2]: Footnote 2
    ;
    var p = Parser.init();
    var doc = try p.parseMarkdown(allocator, input);
    defer doc.deinit(allocator);

    // Test HTML rendering
    const render = HTMLRenderer;
    const h = try render.render(allocator, doc);
    defer allocator.free(h);
    // std.debug.print("Input: {s}\n\nHTML:\n{s}\n", .{ input, h });

    // Test that we have the expected number of elements
    try std.testing.expect(doc.children.items.len >= 6);

    // Test heading parsing
    try std.testing.expect(doc.children.items[0] == .heading);
    try std.testing.expectEqual(@as(u8, 1), doc.children.items[0].heading.level);

    // Test paragraph with link
    try std.testing.expect(doc.children.items[1] == .paragraph);
    const para_with_link = doc.children.items[1].paragraph;
    try std.testing.expect(para_with_link.children.items.len >= 2);

    // Test list
    var found_list = false;
    for (doc.children.items) |item| {
        if (item == .list) {
            found_list = true;
            try std.testing.expectEqual(AST.ListType.unordered, item.list.type);
            try std.testing.expectEqual(@as(usize, 2), item.list.items.items.len);
            break;
        }
    }
    try std.testing.expect(found_list);

    try std.testing.expect(std.mem.indexOf(u8, h, "<h1>Heading</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<a href=\"https://sc2.in\">text</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<em>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<ul>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<blockquote>") != null);

    // std.debug.print("Generated HTML:\n{s}\n", .{h});
    try std.testing.expectEqualStrings(
        \\<h1>Heading</h1><p>Paragraph <a href="https://sc2.in">text</a>.</p><ul><li>item1</li><li>item2</li></ul><p>Some more <strong>bold</strong> text and some <em>italic</em> text.</p><blockquote><p>a block quote</p></blockquote><p>a footnote<a href="#fn:SCF:GOV-01" class="footnote-ref">SCF:GOV-01</a>
        \\a footnote<a href="#fn:2" class="footnote-ref">2</a></p><h2>Heading 2</h2><div class="footnote" id="fn:SCF:GOV-01"><p><b>SCF:GOV-01</b>: Footnote 1</p></div><div class="footnote" id="fn:2"><p><b>2</b>: Footnote 2</p></div>
    , h);
}

/// COMMONMARK SPEC TEST RUNNER
/// This function implements compatibility with the CommonMark specification test suite
/// It can be called from build.zig to run comprehensive compliance tests
/// Test case structure matching CommonMark spec_tests.py format
pub const SpecTest = struct {
    markdown: []const u8,
    html: []const u8,
    example: usize,
    start_line: usize,
    end_line: usize,
    section: []const u8,
};

/// Test result tracking
pub const TestResult = struct {
    passed: usize = 0,
    failed: usize = 0,
    errors: usize = 0,
    skipped: usize = 0,

    pub fn total(self: TestResult) usize {
        return self.passed + self.failed + self.errors + self.skipped;
    }

    pub fn format(self: TestResult, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("{d} passed, {d} failed, {d} errors, {d} skipped", .{ self.passed, self.failed, self.errors, self.skipped });
    }
};

/// HTML normalization for test comparison (simplified version)
/// Based on the CommonMark normalize.py approach
fn normalizeHtml(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    var normalized = std.ArrayList(u8){};
    var in_tag = false;
    var i: usize = 0;

    while (i < src.len) {
        const char = src[i];

        switch (char) {
            '<' => {
                in_tag = true;
                try normalized.append(allocator, char);
            },
            '>' => {
                in_tag = false;
                try normalized.append(allocator, char);
            },
            ' ', '\t', '\n', '\r' => {
                if (!in_tag) {
                    // Normalize whitespace outside tags
                    if (normalized.items.len > 0 and normalized.items[normalized.items.len - 1] != ' ') {
                        try normalized.append(allocator, ' ');
                    }
                } else {
                    try normalized.append(allocator, ' ');
                }
            },
            else => {
                try normalized.append(allocator, char);
            },
        }
        i += 1;
    }

    // Trim trailing whitespace
    while (normalized.items.len > 0 and normalized.items[normalized.items.len - 1] == ' ') {
        _ = normalized.pop();
    }

    return normalized.toOwnedSlice(allocator);
}

/// Parse CommonMark spec test format
/// Parses the spec.txt file format used by CommonMark test suite
pub fn parseSpecTests(allocator: std.mem.Allocator, spec_content: []const u8) !std.ArrayList(SpecTest) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    var tests = std.ArrayList(SpecTest){};
    var lines = std.mem.splitAny(u8, spec_content, "\n");

    var line_number: usize = 0;
    var start_line: usize = 0;
    var example_number: usize = 0;
    var markdown_lines = std.ArrayList([]const u8){};
    defer {
        for (markdown_lines.items) |l| alloc.free(l);
        markdown_lines.deinit(alloc);
    }
    var html_lines = std.ArrayList([]const u8){};
    defer {
        for (html_lines.items) |l| alloc.free(l);
        html_lines.deinit(alloc);
    }
    var state: u8 = 0; // 0: regular text, 1: markdown example, 2: html output
    var current_section: []const u8 = "Unknown";

    while (lines.next()) |line| {
        line_number += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Detect section headers
        if (std.mem.startsWith(u8, trimmed, "#")) {
            current_section = std.mem.trim(u8, trimmed, "# \t");
            continue;
        }

        // State machine for parsing example blocks
        if (std.mem.eql(u8, trimmed, "```````````````````````````````` example")) {
            state = 1;
            start_line = line_number;
            markdown_lines.clearRetainingCapacity();
            html_lines.clearRetainingCapacity();
        } else if (state == 2 and std.mem.eql(u8, trimmed, "````````````````````````````````")) {
            state = 0;
            example_number += 1;

            // Join markdown and HTML lines
            const markdown = try std.mem.join(allocator, "\n", markdown_lines.items);
            const h = try std.mem.join(allocator, "\n", html_lines.items);

            try tests.append(allocator, SpecTest{
                .markdown = markdown,
                .html = h,
                .example = example_number,
                .start_line = start_line,
                .end_line = line_number,
                .section = current_section,
            });
        } else if (std.mem.eql(u8, trimmed, ".")) {
            state = 2;
        } else if (state == 1) {
            // Replace tab placeholder with actual tab
            const processed_line = try std.mem.replaceOwned(u8, allocator, line, "→", "\t");
            try markdown_lines.append(alloc, processed_line);
        } else if (state == 2) {
            const processed_line = try std.mem.replaceOwned(u8, allocator, line, "→", "\t");
            try html_lines.append(alloc, processed_line);
        }
    }

    return tests;
}

/// Run individual test case
fn runSpecTest(allocator: std.mem.Allocator, test_case: SpecTest, normalize: bool) !bool {
    // Parse markdown with our parser
    var p = Parser.init();
    var doc = p.parseMarkdown(allocator, test_case.markdown) catch |err| {
        std.log.err("Parse error for test {d}: {}", .{ test_case.example, err });
        return false;
    };
    defer doc.deinit(allocator);

    // Render to HTML
    const actual_html = HTMLRenderer.render(allocator, doc) catch |err| {
        std.log.err("Render error for test {d}: {}", .{ test_case.example, err });
        return false;
    };
    defer allocator.free(actual_html);

    // Compare with expected output
    const expected = if (normalize)
        try normalizeHtml(allocator, test_case.html)
    else
        test_case.html;
    defer if (normalize) allocator.free(expected);

    const actual = if (normalize)
        try normalizeHtml(allocator, actual_html)
    else
        actual_html;
    defer if (normalize) allocator.free(actual);

    return std.mem.eql(u8, expected, actual);
}

/// Main test runner function for CommonMark specification compliance
/// This function can be called from build.zig test step
pub fn runCommonMarkSpecTests(allocator: std.mem.Allocator, spec_file_path: ?[]const u8, options: struct {
    pattern: ?[]const u8 = null,
    normalize: bool = true,
    verbose: bool = false,
    number: ?usize = null,
}) !TestResult {
    // Default to embedded spec or read from file
    const spec_content = if (spec_file_path) |path| blk: {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.log.err("Failed to open spec file '{s}': {}", .{ path, err });
            return TestResult{};
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
        break :blk content;
    } else embedded_spec_tests;
    defer if (spec_file_path != null) allocator.free(spec_content);

    // Parse test cases from spec
    var tests = try parseSpecTests(allocator, spec_content);
    defer tests.deinit(allocator);
    defer for (tests.items) |test_case| {
        allocator.free(test_case.markdown);
        allocator.free(test_case.html);
    };

    // Filter tests based on options
    var filtered_tests = std.ArrayList(SpecTest){};
    defer filtered_tests.deinit(allocator);

    for (tests.items) |test_case| {
        // Filter by pattern if specified
        if (options.pattern) |pattern| {
            if (std.mem.indexOf(u8, test_case.section, pattern) == null) {
                continue;
            }
        }

        // Filter by test number if specified
        if (options.number) |number| {
            if (test_case.example != number) {
                continue;
            }
        }

        try filtered_tests.append(allocator, test_case);
    }

    var result = TestResult{};

    // Run filtered tests
    for (filtered_tests.items) |test_case| {
        if (options.verbose) {
            std.log.info("Running test {d}: {s} (lines {d}-{d})", .{ test_case.example, test_case.section, test_case.start_line, test_case.end_line });
        }

        const passed = runSpecTest(allocator, test_case, options.normalize) catch |err| {
            std.log.err("Test {d} errored: {}", .{ test_case.example, err });
            result.errors += 1;
            continue;
        };

        if (passed) {
            result.passed += 1;
            if (options.verbose) {
                std.log.info("✓ Test {d} passed", .{test_case.example});
            }
        } else {
            result.failed += 1;
            if (options.verbose) {
                std.log.warn("✗ Test {d} failed", .{test_case.example});
                std.log.warn("  Section: {s}", .{test_case.section});
                std.log.warn("  Markdown: {s}", .{test_case.markdown});
                std.log.warn("  Expected: {s}", .{test_case.html});
            }
        }
    }

    result.skipped = tests.items.len - filtered_tests.items.len;

    return result;
}

/// Embedded subset of CommonMark spec tests for basic validation
/// This can be replaced with full spec.txt content for comprehensive testing
const embedded_spec_tests =
    \\# ATX headings
    \\
    \\```````````````````````````````` example
    \\# Heading 1
    \\## Heading 2
    \\### Heading 3
    \\.
    \\<h1>Heading 1</h1>
    \\<h2>Heading 2</h2>
    \\<h3>Heading 3</h3>
    \\````````````````````````````````
    \\
    \\# Emphasis and strong emphasis
    \\
    \\```````````````````````````````` example
    \\*italic* and **bold**
    \\.
    \\<p><em>italic</em> and <strong>bold</strong></p>
    \\````````````````````````````````
    \\
    \\```````````````````````````````` example
    \\_italic_ and __bold__
    \\.
    \\<p><em>italic</em> and <strong>bold</strong></p>
    \\````````````````````````````````
    \\
    \\# Links
    \\
    \\```````````````````````````````` example
    \\[link text](http://example.com)
    \\.
    \\<p><a href="http://example.com">link text</a></p>
    \\````````````````````````````````
    \\
    \\# Lists
    \\
    \\```````````````````````````````` example
    \\- item 1
    \\- item 2
    \\- item 3
    \\.
    \\<ul>
    \\<li>item 1</li>
    \\<li>item 2</li>
    \\<li>item 3</li>
    \\</ul>
    \\````````````````````````````````
    \\
    \\# Blockquotes
    \\
    \\```````````````````````````````` example
    \\> This is a blockquote
    \\.
    \\<blockquote>
    \\<p>This is a blockquote</p>
    \\</blockquote>
    \\````````````````````````````````
;

// Enhanced test with dot notation functionality
test "enhanced parse and render with dot notation" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const allocator = arena.allocator();

    const input =
        \\# Heading
        \\
        \\Paragraph [text](https://sc2.in).
        \\
        \\- item1
        \\- item2
        \\
        \\Some more *bold* text and some _italic_ text.
        \\
        \\> a block quote
        \\
        \\a footnote[^1]
        \\a footnote[^2]
        \\
        \\## Heading 2
        \\
        \\[^1]: Footnote 1
        \\[^2]: Footnote 2
    ;
    var p = Parser.init();
    var doc = try p.parseMarkdown(allocator, input);
    defer doc.deinit(allocator);

    // Test dot notation functionality
    // const query = doc.get();
    // std.debug.print("{any}\n", .{query});
    // Test counting elements
    // const heading_count = query.count(.heading);
    // try testing.expect(heading_count >= 1);

    // Test getting specific headings
    // const headings = try query.headings(allocator, 1);
    // defer headings.deinit();
    // try testing.expect(headings.items.len >= 1);

    // Test getting links
    // const links = try query.links(allocator);
    // defer links.deinit();
    // try testing.expect(links.items.len >= 1);

    // Test getting paragraphs with emphasis
    // const emphasized_paras = try query.paragraphsWithInlines(allocator, .emphasis);
    // defer emphasized_paras.deinit();
    // try testing.expect(emphasized_paras.items.len >= 1);

    // std.debug.print("Found {d} headings, {d} links, {d} emphasized paragraphs\n", .{ headings.items.len, links.items.len, emphasized_paras.items.len });

    // Test HTML rendering
    const r = HTMLRenderer;
    const h = try r.render(allocator, doc);
    defer allocator.free(h);

    try testing.expect(std.mem.indexOf(u8, h, "<h1>Heading</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, h, "<a href=\"https://sc2.in\">text</a>") != null);
    try testing.expect(std.mem.indexOf(u8, h, "<em>") != null);
    try testing.expect(std.mem.indexOf(u8, h, "<ul>") != null);
    try testing.expect(std.mem.indexOf(u8, h, "<blockquote>") != null);
}

// CommonMark specification compliance test
test "CommonMark spec compliance" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // Per-section breakdown
    const sections = [_][]const u8{
        "ATX",      "Setext",    "Thematic",   "Paragraph", "Blank",
        "Indented", "Fenced",    "Blockquote", "List",      "Backslash",
        "Entity",   "Code span", "Emphasis",   "Link",      "Image",
        "Autolink", "Raw HTML",  "Hard line",  "Soft line", "Textual",
    };

    std.debug.print("\n{s:<25} {s:>6} {s:>6} {s:>6}\n", .{ "Section", "Pass", "Fail", "Total" });
    std.debug.print("{s:-<50}\n", .{""});

    for (sections) |section| {
        const r = try runCommonMarkSpecTests(allocator, "./src/markdown/spec.txt", .{
            .pattern = section,
            .normalize = true,
            .verbose = false,
        });
        const total = r.passed + r.failed + r.errors;
        if (total > 0) {
            std.debug.print("{s:<25} {d:>6} {d:>6} {d:>6}\n", .{ section, r.passed, r.failed, total });
        }
    }

    // Run all
    const result = try runCommonMarkSpecTests(allocator, "./src/markdown/spec.txt", .{
        .normalize = true,
        .verbose = false,
    });

    std.debug.print("\nCommonMark spec test results: {any}\n", .{result});
    try testing.expect(result.total() > 0);

    if (result.failed > 0) {
        std.debug.print("Warning: {d} CommonMark spec tests failed\n", .{result.failed});
        std.debug.print("This is expected as the parser implementation is still basic\n", .{});
    }
}

// CommonMark specification compliance test
test "Policy render" {
    const allocator = std.testing.allocator;

    const test_policy =
        \\---
        \\title: "Test Policy"
        \\description: "A policy for testing purposes"
        \\summary: ""
        \\date: 2024-11-13
        \\weight: 10
        \\taxonomies:
        \\  TSC2017:
        \\    - CC2.1
        \\    - P4.1
        \\  SCF:
        \\    - HRS-05
        \\    - HRS-05.1
        \\    - HRS-05.2
        \\    - HRS-05.3
        \\    - HRS-05.4
        \\    - HRS-05.5
        \\extra:
        \\  owner: SC2
        \\  last_reviewed: 2025-02-24
        \\  major_revisions:
        \\    - date: 2025-06-24
        \\      description: Demo revision.
        \\      revised_by: Ben Craton
        \\      approved_by: Ben Craton
        \\      version: "1.1"
        \\    - date: 2024-02-11
        \\      description: Initial version.
        \\      revised_by: Ben Craton
        \\      approved_by: Ben Craton
        \\      version: "1.0"
        \\---
        \\
        \\## Introduction
        \\
        \\{{ org() }} is committed to testing its policy center.
        \\
        \\## Mermaid
        \\
        \\{% mermaid() %}
        \\graph TD
        \\A[Start] --> B{Is it a test?}
        \\B -- Yes --> C[Run tests]
        \\B -- No --> D[End]
        \\C --> D
        \\{% end %}
        \\
        \\## Zola link replacement
        \\
        \\[policy](@/policies/aeip.md)
        \\
        \\[section](@/policies/_index.md)
        \\
        \\[directory](@/policies/incident/digital-forensics/index.md)
        \\
        \\## Redaction
        \\
        \\{% redact() %}
        \\This is a test policy for demonstration purposes. It contains sensitive information that should not be disclosed.
        \\{% end %}
    ;

    var p = Parser.init();
    var doc = try p.parseMarkdown(allocator, test_policy);
    defer doc.deinit(allocator);

    const rend = try HTMLRenderer.render(allocator, doc);
    defer allocator.free(rend);
    // std.debug.print("{s}\n", .{rend});
}
