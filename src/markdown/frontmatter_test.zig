const std = @import("std");
const tst = std.testing;

const FrontMatter = @import("frontmatter.zig");

// ── Frontmatter QA tests ────────────────────────────────────────────────────

test "frontmatter: YAML basic parsing" {
    const alloc = tst.allocator;
    const source =
        \\title: Hello World
        \\author: Test
    ;
    var fm = try FrontMatter.init(alloc, source, .yaml);
    defer fm.deinit();

    const title = fm.get("title");
    try tst.expect(title != null);
    try tst.expectEqualStrings("Hello World", title.?.string);

    const author = fm.get("author");
    try tst.expect(author != null);
    try tst.expectEqualStrings("Test", author.?.string);
}

test "frontmatter: YAML nested keys" {
    const alloc = tst.allocator;
    const source =
        \\site:
        \\  name: My Site
        \\  url: https://example.com
    ;
    var fm = try FrontMatter.init(alloc, source, .yaml);
    defer fm.deinit();

    const name = fm.get("site.name");
    try tst.expect(name != null);
    try tst.expectEqualStrings("My Site", name.?.string);

    const url = fm.get("site.url");
    try tst.expect(url != null);
    try tst.expectEqualStrings("https://example.com", url.?.string);
}

test "frontmatter: YAML list values" {
    const alloc = tst.allocator;
    const source =
        \\tags:
        \\ - zig
        \\ - markdown
        \\ - parser
    ;
    var fm = try FrontMatter.init(alloc, source, .yaml);
    defer fm.deinit();

    const tags = fm.get("tags");
    try tst.expect(tags != null);
    try tst.expect(tags.? == .array);
    try tst.expectEqual(@as(usize, 3), tags.?.array.items.len);
    try tst.expectEqualStrings("zig", tags.?.array.items[0].string);
}

test "frontmatter: YAML integer and negative values" {
    const alloc = tst.allocator;
    const source =
        \\count: 42
        \\negative: -7
    ;
    var fm = try FrontMatter.init(alloc, source, .yaml);
    defer fm.deinit();

    const count = fm.get("count");
    try tst.expect(count != null);
    try tst.expect(count.? == .integer);
    try tst.expectEqual(@as(i64, 42), count.?.integer);

    const neg = fm.get("negative");
    try tst.expect(neg != null);
    try tst.expect(neg.? == .integer);
    try tst.expectEqual(@as(i64, -7), neg.?.integer);
}

test "frontmatter: YAML boolean values" {
    const alloc = tst.allocator;
    const source =
        \\draft: true
        \\published: false
    ;
    var fm = try FrontMatter.init(alloc, source, .yaml);
    defer fm.deinit();

    const draft = fm.get("draft");
    try tst.expect(draft != null);
    try tst.expect(draft.? == .bool);
    try tst.expect(draft.?.bool == true);

    const published = fm.get("published");
    try tst.expect(published != null);
    try tst.expect(published.? == .bool);
    try tst.expect(published.?.bool == false);
}

test "frontmatter: TOML basic parsing" {
    const alloc = tst.allocator;
    const source =
        \\title = "Hello"
        \\count = 5
    ;
    var fm = try FrontMatter.init(alloc, source, .toml);
    defer fm.deinit();

    const title = fm.get("title");
    try tst.expect(title != null);
    try tst.expectEqualStrings("Hello", title.?.string);

    const count = fm.get("count");
    try tst.expect(count != null);
    try tst.expectEqual(@as(i64, 5), count.?.integer);
}

test "frontmatter: TOML nested tables" {
    const alloc = tst.allocator;
    const source =
        \\[server]
        \\host = "localhost"
        \\port = 8080
    ;
    var fm = try FrontMatter.init(alloc, source, .toml);
    defer fm.deinit();

    const host = fm.get("server.host");
    try tst.expect(host != null);
    try tst.expectEqualStrings("localhost", host.?.string);

    const port = fm.get("server.port");
    try tst.expect(port != null);
    try tst.expectEqual(@as(i64, 8080), port.?.integer);
}

test "frontmatter: TOML arrays" {
    const alloc = tst.allocator;
    const source =
        \\ports = [80, 443, 8080]
    ;
    var fm = try FrontMatter.init(alloc, source, .toml);
    defer fm.deinit();

    const ports = fm.get("ports");
    try tst.expect(ports != null);
    try tst.expect(ports.? == .array);
    try tst.expectEqual(@as(usize, 3), ports.?.array.items.len);
    try tst.expectEqual(@as(i64, 80), ports.?.array.items[0].integer);
    try tst.expectEqual(@as(i64, 443), ports.?.array.items[1].integer);
}

test "frontmatter: TOML boolean" {
    const alloc = tst.allocator;
    const source =
        \\enabled = true
        \\debug = false
    ;
    var fm = try FrontMatter.init(alloc, source, .toml);
    defer fm.deinit();

    const enabled = fm.get("enabled");
    try tst.expect(enabled != null);
    try tst.expectEqualDeep(std.json.Value{ .bool = true }, enabled.?);

    const debug = fm.get("debug");
    try tst.expect(debug != null);
    try tst.expectEqualDeep(std.json.Value{ .bool = false }, debug.?);
}

test "frontmatter: get nonexistent key returns null" {
    const alloc = tst.allocator;
    const source =
        \\title: Hello
    ;
    var fm = try FrontMatter.init(alloc, source, .yaml);
    defer fm.deinit();

    try tst.expect(fm.get("nonexistent") == null);
    try tst.expect(fm.get("title.sub") == null);
    try tst.expect(fm.get("") == null);
}

test "frontmatter: get deeply nested path" {
    const alloc = tst.allocator;
    const source =
        \\a:
        \\  b:
        \\    c:
        \\      d: deep
    ;
    var fm = try FrontMatter.init(alloc, source, .yaml);
    defer fm.deinit();

    const deep = fm.get("a.b.c.d");
    try tst.expect(deep != null);
    try tst.expectEqualStrings("deep", deep.?.string);

    // Partial paths return objects, not null
    const partial = fm.get("a.b");
    try tst.expect(partial != null);
    try tst.expect(partial.? == .object);
}

test "frontmatter: initFromMarkdown YAML" {
    const alloc = tst.allocator;
    const input =
        \\---
        \\title: Test
        \\---
        \\# Content
    ;
    var fm = try FrontMatter.initFromMarkdown(alloc, input);
    defer fm.deinit();

    const title = fm.get("title");
    try tst.expect(title != null);
    try tst.expectEqualStrings("Test", title.?.string);
}

test "frontmatter: initFromMarkdown TOML" {
    const alloc = tst.allocator;
    const input =
        \\+++
        \\title = "Test"
        \\+++
        \\# Content
    ;
    var fm = try FrontMatter.initFromMarkdown(alloc, input);
    defer fm.deinit();

    const title = fm.get("title");
    try tst.expect(title != null);
    try tst.expectEqualStrings("Test", title.?.string);
}

test "frontmatter: initFromMarkdown invalid start" {
    const alloc = tst.allocator;
    const input = "# Just markdown\nNo frontmatter here.";
    try tst.expectError(error.InvalidFrontMatter, FrontMatter.initFromMarkdown(alloc, input));
}

test "frontmatter: initFromMarkdown missing closing delimiter" {
    const alloc = tst.allocator;
    const input =
        \\---
        \\title: Test
        \\No closing delimiter
    ;
    try tst.expectError(error.InvalidFrontMatter, FrontMatter.initFromMarkdown(alloc, input));
}

test "frontmatter: initFromMarkdown empty input" {
    const alloc = tst.allocator;
    try tst.expectError(error.InvalidFrontMatter, FrontMatter.initFromMarkdown(alloc, ""));
}

test "frontmatter: YAML float values" {
    const alloc = tst.allocator;
    const source =
        \\version: 1.5
        \\pi: 3.14
    ;
    var fm = try FrontMatter.init(alloc, source, .yaml);
    defer fm.deinit();

    const version = fm.get("version");
    try tst.expect(version != null);
    try tst.expect(version.? == .float);
    try tst.expectApproxEqAbs(@as(f64, 1.5), version.?.float, 0.001);
}

test "frontmatter: source field preserved" {
    const alloc = tst.allocator;
    const source =
        \\title: Hello
        \\key: value
    ;
    var fm = try FrontMatter.init(alloc, source, .yaml);
    defer fm.deinit();

    try tst.expectEqualStrings(source, fm.source);
}

test "frontmatter: jsonFindByPath on non-object root" {
    const allocator = tst.allocator;
    const json_text = "42";

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_text,
        .{},
    );
    defer parsed.deinit();

    // A scalar root should return null for any dotted path
    const result = FrontMatter.jsonFindByPath(parsed.value, "foo");
    try tst.expect(result == null);
}

test "frontmatter: jsonFindByPath single key" {
    const allocator = tst.allocator;
    const json_text =
        \\{"key": "value"}
    ;

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_text,
        .{},
    );
    defer parsed.deinit();

    const found = FrontMatter.jsonFindByPath(parsed.value, "key");
    try tst.expect(found != null);
    try tst.expectEqualStrings("value", found.?.string);
}
