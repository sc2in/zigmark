//! Frontmatter parser for Markdown documents.
//!
//! Extracts and parses YAML (`---`), TOML (`+++`), JSON (`{`), or ZON (`.{`)
//! frontmatter blocks from the beginning of a Markdown file.  The parsed
//! key/value tree is normalised into `std.json.Value` for uniform downstream
//! access.

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
    /// `std.json.Parsed` owns all json memory in an arena; we must NOT call
    /// `deinitJsonValue` on `.root` for this variant.
    json: std.json.Parsed(JsonValue),
    /// Arena that owns all ZON-parsed memory; same caveat as `.json`.
    zon: std.heap.ArenaAllocator,
};

const Kind = enum {
    yaml,
    toml,
    json,
    zon,
};

/// Parse `source` as frontmatter of `input_kind` (YAML, TOML, JSON, or ZON).
/// Returns a `FrontMatter` whose `.root` field contains the parsed tree.
pub fn init(alloc: Allocator, source: []const u8, input_kind: Kind) !FrontMatter {
    var orig: Origin = undefined;
    const value: JsonValue = switch (input_kind) {
        .yaml => blk: {
            var y = Yaml{ .source = source };
            y.load(alloc) catch |err| switch (err) {
                error.ParseFailure => {
                    std.debug.assert(y.parse_errors.errorMessageCount() > 0);
                    y.parse_errors.renderToStdErr(.{ .ttyconf = std.io.tty.detectConfig(std.fs.File.stderr()) });
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
            var val: tomlz.Value = .{ .table = doc };
            orig = .{ .toml = doc };
            break :blk try tomlValueToJson(alloc, &val);
        },
        .json => blk: {
            const parsed = try std.json.parseFromSlice(JsonValue, alloc, source, .{});
            orig = .{ .json = parsed };
            break :blk parsed.value;
        },
        .zon => blk: {
            var arena = std.heap.ArenaAllocator.init(alloc);
            errdefer arena.deinit();
            const v = try parseZon(arena.allocator(), source);
            orig = .{ .zon = arena };
            break :blk v;
        },
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
    switch (self.original) {
        .yaml => |*o| {
            deinitJsonValue(self.allocator, &self.root);
            o.deinit(self.allocator);
        },
        .toml => |*o| {
            deinitJsonValue(self.allocator, &self.root);
            o.deinit(self.allocator);
        },
        // Arena-based: frees self.root memory too — do NOT call deinitJsonValue.
        .json => |*p| p.deinit(),
        .zon => |*a| a.deinit(),
    }
}

/// Extract and parse frontmatter from a full Markdown document.
///
/// Supported opening markers:
///   `---`  → YAML (closes at next `---`)
///   `+++`  → TOML (closes at next `+++`)
///   `{`    → JSON (self-delimiting object)
///   `.{`   → ZON  (self-delimiting anonymous struct)
pub fn initFromMarkdown(alloc: Allocator, txt: []const u8) !FrontMatter {
    if (txt.len < 3) return error.InvalidFrontMatter;

    // JSON: self-delimiting object starting with '{'
    if (txt[0] == '{') {
        const end = findBraceEnd(txt) orelse return error.InvalidFrontMatter;
        return init(alloc, txt[0..end], .json);
    }

    // ZON: self-delimiting anonymous struct starting with '.{'
    if (txt.len >= 2 and txt[0] == '.' and txt[1] == '{') {
        const end = findBraceEnd(txt[1..]) orelse return error.InvalidFrontMatter;
        return init(alloc, txt[0 .. end + 1], .zon);
    }

    const kind: Kind = switch (txt[0]) {
        '-' => .yaml,
        '+' => .toml,
        else => return error.InvalidFrontMatter,
    };
    const end_fm = std.mem.indexOfPos(u8, txt, 3, if (kind == .yaml) "---" else "+++") orelse
        return error.InvalidFrontMatter;
    return init(alloc, txt[3..end_fm], kind);
}

// ── JSON / ZON helpers ───────────────────────────────────────────────────────

/// Return the index one past the `}` that closes the `{` at `txt[0]`.
/// Accounts for string literals so braces inside strings are ignored.
/// Returns `null` if the input is malformed or has no matching close.
fn findBraceEnd(txt: []const u8) ?usize {
    if (txt.len == 0 or txt[0] != '{') return null;
    var depth: usize = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < txt.len) : (i += 1) {
        const c = txt[i];
        if (in_string) {
            if (c == '\\') {
                i += 1; // skip escaped char
            } else if (c == '"') {
                in_string = false;
            }
        } else switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

/// Parse a ZON value from `source` using `alloc`.
/// Supports: anonymous struct (`.{…}`), array tuple (`.{…}`), strings,
/// numbers (int/float/hex), booleans, null, and enum literals (`.tag`).
fn parseZon(alloc: Allocator, source: []const u8) !JsonValue {
    var p = ZonParser{ .src = source, .pos = 0, .alloc = alloc };
    p.skipWs();
    const v = try p.parseValue();
    return v;
}

const ZonParser = struct {
    src: []const u8,
    pos: usize,
    alloc: Allocator,

    fn skipWs(p: *ZonParser) void {
        while (p.pos < p.src.len) {
            const c = p.src[p.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                p.pos += 1;
            } else if (c == '/' and p.pos + 1 < p.src.len and p.src[p.pos + 1] == '/') {
                while (p.pos < p.src.len and p.src[p.pos] != '\n') p.pos += 1;
            } else break;
        }
    }

    fn peek(p: *ZonParser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn parseValue(p: *ZonParser) anyerror!JsonValue {
        p.skipWs();
        const c = p.peek() orelse return error.ZonParseError;
        return switch (c) {
            '.' => p.parseDot(),
            '"' => p.parseString(),
            '\\' => p.parseMultilineString(),
            '-', '0'...'9' => p.parseNumber(),
            't' => p.parseLit("true", JsonValue{ .bool = true }),
            'f' => p.parseLit("false", JsonValue{ .bool = false }),
            'n' => p.parseLit("null", JsonValue{ .null = {} }),
            else => error.ZonParseError,
        };
    }

    fn parseLit(p: *ZonParser, literal: []const u8, result: JsonValue) !JsonValue {
        if (!std.mem.startsWith(u8, p.src[p.pos..], literal)) return error.ZonParseError;
        p.pos += literal.len;
        return result;
    }

    fn parseDot(p: *ZonParser) !JsonValue {
        p.pos += 1; // consume '.'
        const next = p.peek() orelse return error.ZonParseError;
        if (next == '{') return p.parseStructOrArray();
        // enum literal: .tag_name → string
        const start = p.pos;
        while (p.pos < p.src.len and identChar(p.src[p.pos])) p.pos += 1;
        if (p.pos == start) return error.ZonParseError;
        const s = try p.alloc.dupe(u8, p.src[start..p.pos]);
        return JsonValue{ .string = s };
    }

    fn parseStructOrArray(p: *ZonParser) !JsonValue {
        p.pos += 1; // consume '{'
        p.skipWs();
        if (p.peek() == '}') {
            p.pos += 1;
            return JsonValue{ .object = std.json.ObjectMap.init(p.alloc) };
        }
        return if (p.isStructField()) p.parseStructBody() else p.parseArrayBody();
    }

    /// Lookahead: are we at `.identifier =`?
    fn isStructField(p: *ZonParser) bool {
        if (p.peek() != '.') return false;
        var i = p.pos + 1;
        while (i < p.src.len and identChar(p.src[i])) i += 1;
        if (i == p.pos + 1) return false; // no ident chars
        while (i < p.src.len and wsChar(p.src[i])) i += 1;
        return i < p.src.len and p.src[i] == '=';
    }

    fn parseStructBody(p: *ZonParser) !JsonValue {
        var obj = JsonValue{ .object = std.json.ObjectMap.init(p.alloc) };
        while (true) {
            p.skipWs();
            const c = p.peek() orelse return error.ZonParseError;
            if (c == '}') { p.pos += 1; break; }
            if (c != '.') return error.ZonParseError;
            p.pos += 1; // consume '.'
            const ns = p.pos;
            while (p.pos < p.src.len and identChar(p.src[p.pos])) p.pos += 1;
            if (p.pos == ns) return error.ZonParseError;
            const key = try p.alloc.dupe(u8, p.src[ns..p.pos]);
            p.skipWs();
            if (p.peek() != '=') return error.ZonParseError;
            p.pos += 1; // consume '='
            const val = try p.parseValue();
            try obj.object.put(key, val);
            p.skipWs();
            if (p.peek() == ',') p.pos += 1;
        }
        return obj;
    }

    fn parseArrayBody(p: *ZonParser) !JsonValue {
        var arr = JsonValue{ .array = std.json.Array.init(p.alloc) };
        while (true) {
            p.skipWs();
            if (p.peek() == '}') { p.pos += 1; break; }
            const val = try p.parseValue();
            try arr.array.append(val);
            p.skipWs();
            if (p.peek() == ',') p.pos += 1;
        }
        return arr;
    }

    fn parseString(p: *ZonParser) !JsonValue {
        p.pos += 1; // consume '"'
        var buf: std.ArrayListUnmanaged(u8) = .{};
        while (p.pos < p.src.len) {
            const c = p.src[p.pos];
            if (c == '"') { p.pos += 1; break; }
            if (c == '\\') {
                p.pos += 1;
                if (p.pos >= p.src.len) return error.ZonParseError;
                const esc = p.src[p.pos];
                p.pos += 1;
                switch (esc) {
                    'n' => try buf.append(p.alloc, '\n'),
                    't' => try buf.append(p.alloc, '\t'),
                    'r' => try buf.append(p.alloc, '\r'),
                    '"' => try buf.append(p.alloc, '"'),
                    '\'' => try buf.append(p.alloc, '\''),
                    '\\' => try buf.append(p.alloc, '\\'),
                    'x' => {
                        if (p.pos + 2 > p.src.len) return error.ZonParseError;
                        const byte = std.fmt.parseInt(u8, p.src[p.pos .. p.pos + 2], 16) catch
                            return error.ZonParseError;
                        p.pos += 2;
                        try buf.append(p.alloc, byte);
                    },
                    'u' => {
                        if (p.peek() != '{') return error.ZonParseError;
                        p.pos += 1;
                        const us = p.pos;
                        while (p.pos < p.src.len and p.src[p.pos] != '}') p.pos += 1;
                        const cp = std.fmt.parseInt(u21, p.src[us..p.pos], 16) catch
                            return error.ZonParseError;
                        if (p.pos >= p.src.len) return error.ZonParseError;
                        p.pos += 1; // consume '}'
                        var ubuf: [4]u8 = undefined;
                        const ulen = std.unicode.utf8Encode(cp, &ubuf) catch
                            return error.ZonParseError;
                        try buf.appendSlice(p.alloc, ubuf[0..ulen]);
                    },
                    else => return error.ZonParseError,
                }
            } else {
                try buf.append(p.alloc, c);
                p.pos += 1;
            }
        }
        return JsonValue{ .string = try buf.toOwnedSlice(p.alloc) };
    }

    /// ZON multi-line string: consecutive lines each starting with `\\`.
    fn parseMultilineString(p: *ZonParser) !JsonValue {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        while (p.pos + 1 < p.src.len and
            p.src[p.pos] == '\\' and p.src[p.pos + 1] == '\\')
        {
            p.pos += 2;
            const ls = p.pos;
            while (p.pos < p.src.len and p.src[p.pos] != '\n') p.pos += 1;
            try buf.appendSlice(p.alloc, p.src[ls..p.pos]);
            if (p.pos < p.src.len) { try buf.append(p.alloc, '\n'); p.pos += 1; }
            // skip indentation before next `\\`
            while (p.pos < p.src.len and (p.src[p.pos] == ' ' or p.src[p.pos] == '\t'))
                p.pos += 1;
        }
        return JsonValue{ .string = try buf.toOwnedSlice(p.alloc) };
    }

    fn parseNumber(p: *ZonParser) !JsonValue {
        const start = p.pos;
        const neg = p.src[p.pos] == '-';
        if (neg) p.pos += 1;

        // hex / octal / binary prefix
        if (p.pos + 1 < p.src.len and p.src[p.pos] == '0') {
            switch (p.src[p.pos + 1]) {
                'x', 'X' => {
                    p.pos += 2;
                    while (p.pos < p.src.len and std.ascii.isHex(p.src[p.pos])) p.pos += 1;
                    const n = std.fmt.parseInt(i64, p.src[start..p.pos], 0) catch
                        return error.ZonParseError;
                    return JsonValue{ .integer = n };
                },
                'o' => {
                    p.pos += 2;
                    while (p.pos < p.src.len and p.src[p.pos] >= '0' and p.src[p.pos] <= '7')
                        p.pos += 1;
                    const n = std.fmt.parseInt(i64, p.src[start..p.pos], 0) catch
                        return error.ZonParseError;
                    return JsonValue{ .integer = n };
                },
                'b' => {
                    p.pos += 2;
                    while (p.pos < p.src.len and (p.src[p.pos] == '0' or p.src[p.pos] == '1'))
                        p.pos += 1;
                    const n = std.fmt.parseInt(i64, p.src[start..p.pos], 0) catch
                        return error.ZonParseError;
                    return JsonValue{ .integer = n };
                },
                else => {},
            }
        }

        while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) p.pos += 1;

        const is_float = p.pos < p.src.len and
            (p.src[p.pos] == '.' or p.src[p.pos] == 'e' or p.src[p.pos] == 'E');
        if (is_float) {
            if (p.src[p.pos] == '.') {
                p.pos += 1;
                while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) p.pos += 1;
            }
            if (p.pos < p.src.len and (p.src[p.pos] == 'e' or p.src[p.pos] == 'E')) {
                p.pos += 1;
                if (p.pos < p.src.len and (p.src[p.pos] == '+' or p.src[p.pos] == '-'))
                    p.pos += 1;
                while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) p.pos += 1;
            }
            const f = std.fmt.parseFloat(f64, p.src[start..p.pos]) catch
                return error.ZonParseError;
            return JsonValue{ .float = f };
        }
        const n = std.fmt.parseInt(i64, p.src[start..p.pos], 10) catch
            return error.ZonParseError;
        return JsonValue{ .integer = n };
    }
};

fn identChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn wsChar(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
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

    // var buf: [1024]u8 = undefined;
    // var fbs = std.io.fixedBufferStream(&buf);
    // try std.json.stringify(json_value, .{}, fbs.writer());
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
        .scalar => |s| {
            const value = blk: {
                break :blk JsonValue{ .float = std.fmt.parseFloat(f32, s) catch {
                    break :blk JsonValue{ .integer = std.fmt.parseInt(u32, s, 10) catch {
                        break :blk JsonValue{ .string = s };
                    } };
                } };
            };
            return value;
        },

        .boolean => |b| {
            return JsonValue{ .bool = b };
        },
        .empty => {
            return JsonValue{ .null = {} };
        },
        // else => |u| {
        //     std.debug.print("Unsuported type: {}\n", .{u});
        //     return error.UnsupportedYamlType;
        // },
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

    // var buf: [1024]u8 = undefined;
    // var fbs = std.io.fixedBufferStream(&buf);
    // try std.json.stringify(json_value, .{}, fbs.writer());
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
    if (path.len == 0) return null;
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
