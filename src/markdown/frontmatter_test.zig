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
    try tst.expect(count.? == .float);
    try tst.expectApproxEqAbs(@as(f64, 42), count.?.float, 0.001);

    const neg = fm.get("negative");
    try tst.expect(neg != null);
    try tst.expect(neg.? == .float);
    try tst.expectApproxEqAbs(@as(f64, -7), neg.?.float, 0.001);
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
    try tst.expect(draft.? == .string);
    try tst.expectEqualStrings("true", draft.?.string);

    const published = fm.get("published");
    try tst.expect(published != null);
    try tst.expect(published.? == .string);
    try tst.expectEqualStrings("false", published.?.string);
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

    const n1 = fm.get("nonexistent");
    const n2 = fm.get("title.sub");
    const n3 = fm.get("");
    if (n1 != null or n2 != null or n3 != null) {
        std.debug.print("nonexistent: {any}, title.sub: {any}, empty: {any}\n", .{ n1, n2, n3 });
    }
    try tst.expect(n1 == null);
    try tst.expect(n2 == null);
    try tst.expect(n3 == null);
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
    tst.expect(version != null) catch |e| {
        std.debug.print("version missing: {any}\n", .{version});
        return e;
    };
    if (version.? == .float) {
        try tst.expectApproxEqAbs(@as(f64, 1.5), version.?.float, 0.001);
    } else if (version.? == .integer) {
        try tst.expectEqual(@as(i64, 1), version.?.integer);
    } else {
        std.debug.print("version value: {any}\n", .{version});
        return error.UnexpectedType;
    }
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
    if (found == null) {
        std.debug.print("jsonFindByPath returned null for key\n", .{});
    }
    try tst.expect(found != null);
    try tst.expectEqualStrings("value", found.?.string);
}

// ── JSON frontmatter tests ───────────────────────────────────────────────────

test "frontmatter: JSON basic parsing" {
    const alloc = tst.allocator;
    const source =
        \\{"title": "Hello", "count": 5}
    ;
    var fm = try FrontMatter.init(alloc, source, .json);
    defer fm.deinit();

    const title = fm.get("title");
    try tst.expect(title != null);
    try tst.expectEqualStrings("Hello", title.?.string);

    const count = fm.get("count");
    try tst.expect(count != null);
    try tst.expectEqual(@as(i64, 5), count.?.integer);
}

test "frontmatter: JSON nested object" {
    const alloc = tst.allocator;
    const source =
        \\{"site": {"name": "My Site", "url": "https://example.com"}}
    ;
    var fm = try FrontMatter.init(alloc, source, .json);
    defer fm.deinit();

    const name = fm.get("site.name");
    try tst.expect(name != null);
    try tst.expectEqualStrings("My Site", name.?.string);
}

test "frontmatter: JSON arrays" {
    const alloc = tst.allocator;
    const source =
        \\{"tags": ["zig", "wasm", "markdown"]}
    ;
    var fm = try FrontMatter.init(alloc, source, .json);
    defer fm.deinit();

    const tags = fm.get("tags");
    try tst.expect(tags != null);
    try tst.expect(tags.? == .array);
    try tst.expectEqual(@as(usize, 3), tags.?.array.items.len);
    try tst.expectEqualStrings("zig", tags.?.array.items[0].string);
}

test "frontmatter: JSON booleans and null" {
    const alloc = tst.allocator;
    const source =
        \\{"draft": true, "published": false, "extra": null}
    ;
    var fm = try FrontMatter.init(alloc, source, .json);
    defer fm.deinit();

    try tst.expectEqualDeep(std.json.Value{ .bool = true }, fm.get("draft").?);
    try tst.expectEqualDeep(std.json.Value{ .bool = false }, fm.get("published").?);
    try tst.expectEqualDeep(std.json.Value{ .null = {} }, fm.get("extra").?);
}

test "frontmatter: initFromMarkdown JSON" {
    const alloc = tst.allocator;
    const input =
        \\{"title": "Test", "weight": 10}
        \\# Content
    ;
    var fm = try FrontMatter.initFromMarkdown(alloc, input);
    defer fm.deinit();

    try tst.expectEqualStrings("Test", fm.get("title").?.string);
    try tst.expectEqual(@as(i64, 10), fm.get("weight").?.integer);
}

// ── ZON frontmatter tests ────────────────────────────────────────────────────

test "frontmatter: ZON basic parsing" {
    const alloc = tst.allocator;
    const source =
        \\.{
        \\    .title = "Hello World",
        \\    .count = 42,
        \\}
    ;
    var fm = try FrontMatter.init(alloc, source, .zon);
    defer fm.deinit();

    const title = fm.get("title");
    try tst.expect(title != null);
    try tst.expectEqualStrings("Hello World", title.?.string);

    const count = fm.get("count");
    try tst.expect(count != null);
    try tst.expectEqual(@as(i64, 42), count.?.integer);
}

test "frontmatter: ZON nested struct" {
    const alloc = tst.allocator;
    const source =
        \\.{
        \\    .site = .{
        \\        .name = "My Site",
        \\        .url = "https://example.com",
        \\    },
        \\}
    ;
    var fm = try FrontMatter.init(alloc, source, .zon);
    defer fm.deinit();

    const name = fm.get("site.name");
    try tst.expect(name != null);
    try tst.expectEqualStrings("My Site", name.?.string);
}

test "frontmatter: ZON array" {
    const alloc = tst.allocator;
    const source =
        \\.{
        \\    .tags = .{ "zig", "wasm", "markdown" },
        \\}
    ;
    var fm = try FrontMatter.init(alloc, source, .zon);
    defer fm.deinit();

    const tags = fm.get("tags");
    try tst.expect(tags != null);
    try tst.expect(tags.? == .array);
    try tst.expectEqual(@as(usize, 3), tags.?.array.items.len);
    try tst.expectEqualStrings("zig", tags.?.array.items[0].string);
}

test "frontmatter: ZON booleans and null" {
    const alloc = tst.allocator;
    const source =
        \\.{
        \\    .draft = true,
        \\    .published = false,
        \\    .extra = null,
        \\}
    ;
    var fm = try FrontMatter.init(alloc, source, .zon);
    defer fm.deinit();

    try tst.expectEqualDeep(std.json.Value{ .bool = true }, fm.get("draft").?);
    try tst.expectEqualDeep(std.json.Value{ .bool = false }, fm.get("published").?);
    try tst.expectEqualDeep(std.json.Value{ .null = {} }, fm.get("extra").?);
}

test "frontmatter: ZON numbers — int, negative, float" {
    const alloc = tst.allocator;
    const source =
        \\.{
        \\    .weight = 10,
        \\    .offset = -3,
        \\    .version = 1.5,
        \\    .hex = 0xFF,
        \\}
    ;
    var fm = try FrontMatter.init(alloc, source, .zon);
    defer fm.deinit();

    try tst.expectEqual(@as(i64, 10), fm.get("weight").?.integer);
    try tst.expectEqual(@as(i64, -3), fm.get("offset").?.integer);
    try tst.expectApproxEqAbs(@as(f64, 1.5), fm.get("version").?.float, 0.001);
    try tst.expectEqual(@as(i64, 255), fm.get("hex").?.integer);
}

test "frontmatter: ZON enum literal becomes string" {
    const alloc = tst.allocator;
    const source =
        \\.{ .status = .published }
    ;
    var fm = try FrontMatter.init(alloc, source, .zon);
    defer fm.deinit();

    try tst.expectEqualStrings("published", fm.get("status").?.string);
}

test "frontmatter: initFromMarkdown ZON" {
    const alloc = tst.allocator;
    const input =
        \\.{ .title = "Test", .weight = 7 }
        \\# Content
    ;
    var fm = try FrontMatter.initFromMarkdown(alloc, input);
    defer fm.deinit();

    try tst.expectEqualStrings("Test", fm.get("title").?.string);
    try tst.expectEqual(@as(i64, 7), fm.get("weight").?.integer);
}

// ── serialize / toMarkdown tests ─────────────────────────────────────────────

test "frontmatter: serialize YAML round-trip" {
    const alloc = tst.allocator;
    // Note: zig-yaml represents YAML booleans as strings, so we test
    // string, integer, and float values here — types it does round-trip.
    const input =
        \\---
        \\title: Hello World
        \\weight: 5
        \\---
        \\# Content
    ;
    var fm = try FrontMatter.initFromMarkdown(alloc, input);
    defer fm.deinit();

    const out = try fm.serialize(alloc);
    defer alloc.free(out);

    // Must start and end with delimiters
    try tst.expect(std.mem.startsWith(u8, out, "---\n"));
    try tst.expect(std.mem.endsWith(u8, out, "---\n"));
    // Re-parse and verify values survived the round-trip.
    // Note: zig-yaml's scalar converter tries parseFloat before parseInt, so
    // integers may come back as .float — accept either representation.
    var fm2 = try FrontMatter.initFromMarkdown(alloc, out);
    defer fm2.deinit();
    try tst.expectEqualStrings("Hello World", fm2.get("title").?.string);
    const weight = fm2.get("weight").?;
    switch (weight) {
        .integer => |n| try tst.expectEqual(@as(i64, 5), n),
        .float => |f| try tst.expectApproxEqAbs(@as(f64, 5.0), f, 0.001),
        else => return error.UnexpectedType,
    }
}

test "frontmatter: serialize YAML nested and array" {
    const alloc = tst.allocator;
    const source =
        \\tags:
        \\  - zig
        \\  - markdown
        \\extra:
        \\  owner: SC2
    ;
    var fm = try FrontMatter.init(alloc, source, .yaml);
    defer fm.deinit();

    const out = try fm.serialize(alloc);
    defer alloc.free(out);

    var fm2 = try FrontMatter.initFromMarkdown(alloc, out);
    defer fm2.deinit();
    try tst.expectEqualStrings("zig", fm2.get("tags").?.array.items[0].string);
    try tst.expectEqualStrings("SC2", fm2.get("extra.owner").?.string);
}

test "frontmatter: serialize TOML round-trip" {
    const alloc = tst.allocator;
    const input =
        \\+++
        \\title = "My Post"
        \\weight = 3
        \\draft = false
        \\+++
        \\# Content
    ;
    var fm = try FrontMatter.initFromMarkdown(alloc, input);
    defer fm.deinit();

    const out = try fm.serialize(alloc);
    defer alloc.free(out);

    try tst.expect(std.mem.startsWith(u8, out, "+++\n"));
    try tst.expect(std.mem.endsWith(u8, out, "+++\n"));
    var fm2 = try FrontMatter.initFromMarkdown(alloc, out);
    defer fm2.deinit();
    try tst.expectEqualStrings("My Post", fm2.get("title").?.string);
    try tst.expectEqual(@as(i64, 3), fm2.get("weight").?.integer);
    try tst.expectEqualDeep(std.json.Value{ .bool = false }, fm2.get("draft").?);
}

test "frontmatter: serialize TOML nested section" {
    const alloc = tst.allocator;
    const source =
        \\title = "Post"
        \\
        \\[extra]
        \\owner = "SC2"
    ;
    var fm = try FrontMatter.init(alloc, source, .toml);
    defer fm.deinit();

    const out = try fm.serialize(alloc);
    defer alloc.free(out);

    var fm2 = try FrontMatter.initFromMarkdown(alloc, out);
    defer fm2.deinit();
    try tst.expectEqualStrings("Post", fm2.get("title").?.string);
    try tst.expectEqualStrings("SC2", fm2.get("extra.owner").?.string);
}

test "frontmatter: serialize JSON round-trip" {
    const alloc = tst.allocator;
    const input =
        \\{"title": "Test", "weight": 10, "draft": true}
        \\# Content
    ;
    var fm = try FrontMatter.initFromMarkdown(alloc, input);
    defer fm.deinit();

    const out = try fm.serialize(alloc);
    defer alloc.free(out);

    var fm2 = try FrontMatter.initFromMarkdown(alloc, out);
    defer fm2.deinit();
    try tst.expectEqualStrings("Test", fm2.get("title").?.string);
    try tst.expectEqual(@as(i64, 10), fm2.get("weight").?.integer);
    try tst.expectEqualDeep(std.json.Value{ .bool = true }, fm2.get("draft").?);
}

test "frontmatter: serialize ZON round-trip" {
    const alloc = tst.allocator;
    const input =
        \\.{ .title = "ZON Post", .draft = false, .weight = 7 }
        \\# Content
    ;
    var fm = try FrontMatter.initFromMarkdown(alloc, input);
    defer fm.deinit();

    const out = try fm.serialize(alloc);
    defer alloc.free(out);

    var fm2 = try FrontMatter.initFromMarkdown(alloc, out);
    defer fm2.deinit();
    try tst.expectEqualStrings("ZON Post", fm2.get("title").?.string);
    try tst.expectEqualDeep(std.json.Value{ .bool = false }, fm2.get("draft").?);
    try tst.expectEqual(@as(i64, 7), fm2.get("weight").?.integer);
}

test "frontmatter: toMarkdown reattaches body" {
    const alloc = tst.allocator;
    const source =
        \\---
        \\title: Hello
        \\---
        \\
        \\## Body content
    ;
    var fm = try FrontMatter.initFromMarkdown(alloc, source);
    defer fm.deinit();

    const body = "## Body content";
    const doc = try fm.toMarkdown(alloc, body);
    defer alloc.free(doc);

    try tst.expect(std.mem.startsWith(u8, doc, "---\n"));
    try tst.expect(std.mem.indexOf(u8, doc, "## Body content") != null);
}
