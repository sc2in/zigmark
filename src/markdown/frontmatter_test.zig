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
    tst.expect(count != null) catch |e| {
        std.debug.print("count missing: {any}\n", .{count});
        return e;
    };
    std.debug.print("count type: {s}\n", .{@tagName(count.?)});
    if (count.? == .float) {
        try tst.expectApproxEqAbs(@as(f64, 42), count.?.float, 0.001);
    } else if (count.? == .integer) {
        try tst.expectEqual(@as(i64, 42), count.?.integer);
    } else {
        std.debug.print("count value: {any}\n", .{count});
        return error.UnexpectedType;
    }

    const neg = fm.get("negative");
    tst.expect(neg != null) catch |e| {
        std.debug.print("negative missing: {any}\n", .{neg});
        return e;
    };
    std.debug.print("negative type: {s}\n", .{@tagName(neg.?)});
    if (neg.? == .float) {
        try tst.expectApproxEqAbs(@as(f64, -7), neg.?.float, 0.001);
    } else if (neg.? == .integer) {
        try tst.expectEqual(@as(i64, -7), neg.?.integer);
    } else {
        std.debug.print("negative value: {any}\n", .{neg});
        return error.UnexpectedType;
    }
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
    tst.expect(draft != null) catch |e| {
        std.debug.print("draft missing: {any}\n", .{draft});
        return e;
    };
    std.debug.print("draft type: {s}\n", .{@tagName(draft.?)});
    if (draft.? == .bool) {
        try tst.expect(draft.?.bool == true);
    } else if (draft.? == .string) {
        try tst.expectEqualStrings("true", draft.?.string);
    } else {
        std.debug.print("draft value: {any}\n", .{draft});
        return error.UnexpectedType;
    }

    const published = fm.get("published");
    tst.expect(published != null) catch |e| {
        std.debug.print("published missing: {any}\n", .{published});
        return e;
    };
    std.debug.print("published type: {s}\n", .{@tagName(published.?)});
    if (published.? == .bool) {
        try tst.expect(published.?.bool == false);
    } else if (published.? == .string) {
        try tst.expectEqualStrings("false", published.?.string);
    } else {
        std.debug.print("published value: {any}\n", .{published});
        return error.UnexpectedType;
    }
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
    std.debug.print("version type: {s}\n", .{@tagName(version.?)});
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
    try tst.expect(found != null);
    try tst.expectEqualStrings("value", found.?.string);
}
