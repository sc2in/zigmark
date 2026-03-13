//! Frontmatter parser for Markdown documents.
//!
//! Extracts and parses YAML (`---`) or TOML (`+++`) frontmatter blocks
//! from the beginning of a Markdown file.  The parsed key/value tree is
//! normalised into `std.json.Value` for uniform downstream access.

const std = @import("std");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;
const tst = std.testing;
const math = std.math;
const JsonValue = std.json.Value;

const tomlz = @import("tomlz");
const Yaml = @import("yaml").Yaml;

const FrontMatter = @This();

allocator: Allocator,
/// The parsed frontmatter as a JSON value tree.
root: JsonValue,
/// The raw frontmatter source text (without delimiters).
source: []const u8,
original: Origin,

const Origin = union(Kind) {
    yaml: Yaml,
    toml: tomlz.Table,
};

const Kind = enum {
    yaml,
    toml,
};

/// Parse `source` as frontmatter of `input_kind` (YAML or TOML).
/// Returns a `FrontMatter` whose `.root` field contains the parsed tree.
pub fn init(alloc: Allocator, source: []const u8, input_kind: Kind) !FrontMatter {
    var orig: Origin = undefined;
    const value: JsonValue = switch (input_kind) {
        .yaml => blk: {
            var y = Yaml{ .source = source };
            // defer y.deinit(alloc);

            y.load(alloc) catch |err| switch (err) {
                error.ParseFailure => {
                    std.debug.assert(y.parse_errors.errorMessageCount() > 0);
                    y.parse_errors.renderToStdErr(.{ .ttyconf = std.io.tty.detectConfig(std.io.getStdErr()) });
                    return error.ParseFailure;
                },
                else => return err,
            };
            orig = .{ .yaml = y };
            const doc = y.docs.items[0];
            break :blk try yamlNodeToJson(alloc, doc);
        },
        .toml => blk: {
            const doc = try tomlz.parser.parse(alloc, source);
            // defer doc.deinit(alloc);

            var val: tomlz.Value = .{ .table = doc };
            orig = .{ .toml = doc };
            break :blk try tomlValueToJson(alloc, &val);
        },
        // else => return error.UnhandledSourceType,
    };
    return .{
        .allocator = alloc,
        .source = source,
        .root = value,
        .original = orig,
    };
}
/// Release all memory owned by this `FrontMatter` instance.
pub fn deinit(self: *FrontMatter) void {
    deinitJsonValue(self.allocator, &self.root);
    switch (self.original) {
        inline else => |*o| o.deinit(self.allocator),
    }
}

/// Extract and parse frontmatter from a full Markdown document.
///
/// The first line must be `---` (YAML) or `+++` (TOML).  The
/// frontmatter extends to the next matching delimiter.
pub fn initFromMarkdown(alloc: Allocator, txt: []const u8) !FrontMatter {
    if (txt.len < 3) return error.InvalidFrontMatter;
    const kind: Kind = switch (txt[0]) {
        '-' => .yaml,
        '+' => .toml,
        else => return error.InvalidFrontMatter,
    };
    const end_fm = std.mem.indexOfPos(u8, txt, 3, if (kind == .yaml) "---" else if (kind == .toml) "+++" else "") orelse return error.InvalidFrontMatter;
    return init(alloc, txt[3..end_fm], kind);
}

test {
    const alloc = tst.allocator;
    const source =
        \\your: yaml
        \\goes: here
        \\list:
        \\ - item1
        \\ - item2
        \\nested:
        \\  key: value
        \\thing: -1
        \\date: 2025-06-01
        \\version: 1.2
    ;
    var fm = try FrontMatter.init(alloc, source, .yaml);
    defer fm.deinit();

    const source2 =
        \\#Useless spaces eliminated.
        \\title="TOML Example"
        \\[owner]
        \\name="Lance Uppercut"
        // \\dob=1979-05-27T07:32:00-08:00#First class dates
        \\[database]
        \\server="192.168.1.1"
        \\ports=[8001,8001,8002]
        \\connection_max=5000
        \\enabled=true
        \\[servers]
        \\[servers.alpha]
        \\ip="10.0.0.1"
        \\dc="eqdc10"
        \\[servers.beta]
        \\ip="10.0.0.2"
        \\dc="eqdc10"
        \\[clients]
        \\data=[["gamma","delta"],[1,2]]
        \\hosts=[
        \\"alpha",
        \\"omega"
        \\]
    ;
    var fm2 = try FrontMatter.init(alloc, source2, .toml);
    defer fm2.deinit();
    const find = jsonFindByPath(fm2.root, "database.enabled").?;
    try tst.expectEqualDeep(JsonValue{ .bool = true }, find);
}

test {
    const alloc = tst.allocator;
    const source =
        \\your: yaml
        \\goes: here
        \\list:
        \\ - item1
        \\ - item2
        \\nested:
        \\  key: value
        \\thing: -1
        \\date: 2025-06-01
        \\version: 1.2
    ;

    var y = Yaml{ .source = source };
    defer y.deinit(alloc);

    try y.load(alloc);
    const doc = y.docs.items[0];
    var json_value = try yamlNodeToJson(alloc, doc);
    defer deinitJsonValue(alloc, &json_value);

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try std.json.stringify(json_value, .{}, fbs.writer());
    // const json_str = fbs.getWritten();
    // std.debug.print("{s}\n", .{json_str});
}
fn deinitJsonValue(alloc: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .object => |*o| {
            for (o.values()) |*v|
                deinitJsonValue(alloc, v);
            o.deinit();
        },
        .array => |*a| {
            for (a.items) |*i|
                deinitJsonValue(alloc, i);
            a.deinit();
        },
        else => {},
    }
}

/// Recursively convert a `zig-yaml` value tree into `std.json.Value`.
pub fn yamlNodeToJson(allocator: std.mem.Allocator, node: Yaml.Value) !JsonValue {
    switch (node) {
        .map => |m| {
            var object = JsonValue{ .object = .init(allocator) };
            var iter = m.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr;
                const value = try yamlNodeToJson(allocator, entry.value_ptr.*);
                try object.object.put(key.*, value);
            }
            return object;
        },
        .list => |l| {
            var list = JsonValue{ .array = .init(allocator) };
            for (l) |val| {
                const value = try yamlNodeToJson(allocator, val);
                try list.array.append(value);
            }
            return list;
        },
        .string => |s| {
            return JsonValue{ .string = s };
        },
        .int => |i| {
            return JsonValue{ .integer = i };
        },
        .float => |f| {
            return JsonValue{ .float = f };
        },
        .boolean => |b| {
            return JsonValue{ .bool = b };
        },
        else => |u| {
            std.debug.print("Unsuported type: {}\n", .{u});
            return error.UnsupportedYamlType;
        },
    }
}

test "toml to json conversion" {
    const alloc = std.testing.allocator;
    const source =
        \\#Useless spaces eliminated.
        \\title="TOML Example"
        \\[owner]
        \\name="Lance Uppercut"
        // \\dob=1979-05-27T07:32:00-08:00#First class dates
        \\[database]
        \\server="192.168.1.1"
        \\ports=[8001,8001,8002]
        \\connection_max=5000
        \\enabled=true
        \\[servers]
        \\[servers.alpha]
        \\ip="10.0.0.1"
        \\dc="eqdc10"
        \\[servers.beta]
        \\ip="10.0.0.2"
        \\dc="eqdc10"
        \\[clients]
        \\data=[["gamma","delta"],[1,2]]
        \\hosts=[
        \\"alpha",
        \\"omega"
        \\]
    ;

    var doc = try tomlz.parser.parse(alloc, source);
    defer doc.deinit(alloc);

    var val: tomlz.Value = .{ .table = doc };
    var json_value = try tomlValueToJson(alloc, &val);
    defer deinitJsonValue(alloc, &json_value);

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try std.json.stringify(json_value, .{}, fbs.writer());
    // const json_str = fbs.getWritten();
    // std.debug.print("{s}\n", .{json_str});
}
/// Recursively convert a `tomlz` value tree into `std.json.Value`.
pub fn tomlValueToJson(allocator: std.mem.Allocator, v: *tomlz.parser.Value) !std.json.Value {
    return switch (v.*) {
        .string => |s| std.json.Value{ .string = s },
        .integer => |s| std.json.Value{ .integer = s },
        .float => |f| std.json.Value{ .float = f },
        .boolean => |b| std.json.Value{ .bool = b },
        .array => |*a| b: {
            var al = try std.json.Array.initCapacity(allocator, a.array.items.len);
            for (a.array.items) |*value| {
                al.appendAssumeCapacity(try tomlValueToJson(allocator, value));
            }
            break :b std.json.Value{ .array = al };
        },
        .table => |*t| try tableToJson(allocator, t),
    };
}

/// Convert a `tomlz` table into a `std.json.Value` object map.
pub fn tableToJson(allocator: std.mem.Allocator, table: *tomlz.parser.Table) error{OutOfMemory}!std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer obj.deinit();

    var it = table.table.iterator();
    while (it.next()) |entry| {
        const v = try tomlValueToJson(allocator, entry.value_ptr);
        try obj.put(entry.key_ptr.*, v);
    }

    return std.json.Value{ .object = obj };
}

/// Look up a value by dot-separated key path (e.g. `"extra.owner"`).
pub fn get(self: FrontMatter, path: []const u8) ?std.json.Value {
    return jsonFindByPath(self.root, path);
}

/// Looks up a value in a std.json.Value tree using a dot-separated key path.
/// Returns the found value, or null if any part of the path is missing.
pub fn jsonFindByPath(root: std.json.Value, path: []const u8) ?std.json.Value {
    var it = std.mem.tokenizeScalar(u8, path, '.');
    var current = root;
    while (it.next()) |segment| {
        if (current != .object) return null;
        const found = current.object.get(segment);
        if (found == null) return null;
        current = found.?;
    }
    return current;
}

test "jsonFindByPath works" {
    const allocator = tst.allocator;

    const json_text =
        \\{
        \\  "foo": {
        \\    "bar": {
        \\      "baz": 123
        \\    }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(
        JsonValue,
        allocator,
        json_text,
        .{},
    );
    defer parsed.deinit();

    const root = parsed.value;
    const found = jsonFindByPath(root, "foo.bar.baz");
    try tst.expect(found != null);
    try tst.expect(found.? == .integer);
    try tst.expect(found.?.integer == 123);

    const not_found = jsonFindByPath(root, "foo.bar.qux");
    try tst.expect(not_found == null);
}

// tera integration test moved to the standalone tera package

test {
    _ = @import("frontmatter_test.zig");
}
