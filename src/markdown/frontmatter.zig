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
/// Arena that owns all memory allocated by `set()` and `merge()`.
/// Lazily initialised on first mutation; freed by `deinit()`.
set_arena: ?std.heap.ArenaAllocator = null,

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
    if (self.set_arena) |*a| a.deinit();
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

/// Deep-clone a `std.json.Value` tree using `alloc`.
/// Strings and number_string values are duplicated; scalars are copied by value.
/// The caller owns all allocated memory; free with `deinitJsonValue` for
/// containers (note: string values must be freed separately if needed).
pub fn cloneJsonValue(alloc: Allocator, value: std.json.Value) Allocator.Error!std.json.Value {
    return switch (value) {
        .null => .{ .null = {} },
        .bool => |b| .{ .bool = b },
        .integer => |n| .{ .integer = n },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try alloc.dupe(u8, s) },
        .string => |s| .{ .string = try alloc.dupe(u8, s) },
        .array => |arr| blk: {
            var new_arr = try std.json.Array.initCapacity(alloc, arr.items.len);
            for (arr.items) |item| {
                new_arr.appendAssumeCapacity(try cloneJsonValue(alloc, item));
            }
            break :blk .{ .array = new_arr };
        },
        .object => |obj| blk: {
            var new_obj: std.json.ObjectMap = .init(alloc);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try alloc.dupe(u8, entry.key_ptr.*);
                const val = try cloneJsonValue(alloc, entry.value_ptr.*);
                try new_obj.put(key, val);
            }
            break :blk .{ .object = new_obj };
        },
    };
}

/// Recursively deep-merge `overlay` into `base` using `alloc`.
/// For `.object` values: recurse (overlay keys win on leaf conflicts).
/// For all other types: overlay value replaces the base value (cloned).
fn mergeJsonValue(alloc: Allocator, base: *std.json.Value, overlay: std.json.Value) Allocator.Error!void {
    if (base.* == .object and overlay == .object) {
        var it = overlay.object.iterator();
        while (it.next()) |entry| {
            if (base.object.getPtr(entry.key_ptr.*)) |existing| {
                try mergeJsonValue(alloc, existing, entry.value_ptr.*);
            } else {
                const key = try alloc.dupe(u8, entry.key_ptr.*);
                const val = try cloneJsonValue(alloc, entry.value_ptr.*);
                try base.object.put(key, val);
            }
        }
    } else {
        base.* = try cloneJsonValue(alloc, overlay);
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

/// Remove the key at `path` from `self.root`.
/// Returns `true` if the key existed and was removed, `false` otherwise.
pub fn delete(self: *FrontMatter, path: []const u8) bool {
    if (path.len == 0 or self.root != .object) return false;
    var segs = std.mem.tokenizeScalar(u8, path, '.');
    var current: *std.json.Value = &self.root;
    while (segs.next()) |seg| {
        const is_last = segs.rest().len == 0;
        if (current.* != .object) return false;
        if (is_last) return current.object.orderedRemove(seg);
        current = current.object.getPtr(seg) orelse return false;
    }
    return false;
}

/// Return the byte offset in `txt` where the Markdown body begins —
/// i.e. the first byte after the frontmatter block and its closing
/// delimiter (including a trailing newline if present).
///
/// Returns `null` when `txt` does not start with recognizable frontmatter.
pub fn bodyOffset(txt: []const u8) ?usize {
    if (txt.len < 3) return null;

    // JSON: self-delimiting `{…}`
    if (txt[0] == '{') {
        const end = findBraceEnd(txt) orelse return null;
        return if (end < txt.len and txt[end] == '\n') end + 1 else end;
    }

    // ZON: self-delimiting `.{…}`
    if (txt.len >= 2 and txt[0] == '.' and txt[1] == '{') {
        const end = findBraceEnd(txt[1..]) orelse return null;
        const abs = end + 1;
        return if (abs < txt.len and txt[abs] == '\n') abs + 1 else abs;
    }

    const marker: []const u8 = switch (txt[0]) {
        '-' => "---",
        '+' => "+++",
        else => return null,
    };
    const close = std.mem.indexOfPos(u8, txt, 3, marker) orelse return null;
    var end = close + 3;
    if (end < txt.len and txt[end] == '\n') end += 1;
    return end;
}

/// Set (or create) a value at a dot-separated key path in `self.root`.
/// Intermediate objects that do not exist are created automatically.
/// The provided `value` is deep-cloned; all new allocations are owned by
/// an internal arena and freed when `deinit()` is called.
///
/// Returns `error.InvalidFieldArg` for an empty path and
/// `error.NotAnObject` if traversal hits a non-object intermediate node.
pub fn set(self: *FrontMatter, path: []const u8, value: std.json.Value) !void {
    if (path.len == 0) return error.InvalidFieldArg;
    if (self.root != .object) return error.NotAnObject;
    if (self.set_arena == null)
        self.set_arena = std.heap.ArenaAllocator.init(self.allocator);
    const alloc = self.set_arena.?.allocator();
    const owned = try cloneJsonValue(alloc, value);
    var segs = std.mem.tokenizeScalar(u8, path, '.');
    var current: *std.json.Value = &self.root;
    while (segs.next()) |seg| {
        const is_last = segs.rest().len == 0;
        if (is_last) {
            const key = try alloc.dupe(u8, seg);
            try current.object.put(key, owned);
            return;
        }
        if (current.object.getPtr(seg)) |child| {
            if (child.* != .object) return error.NotAnObject;
            current = child;
        } else {
            const key = try alloc.dupe(u8, seg);
            try current.object.put(key, .{ .object = .init(alloc) });
            current = current.object.getPtr(seg).?;
        }
    }
}

/// Deep-merge `overlay.root` into `self.root`.
///
/// For object values the merge is recursive: overlay keys are added or
/// overwrite matching base keys; unmatched base keys are preserved.
/// For all other value types the overlay wins outright.
/// `self` retains its original format (YAML/TOML/JSON/ZON); the overlay's
/// format is ignored.  All new allocations go into the internal set-arena
/// and are freed by `deinit()`.
pub fn merge(self: *FrontMatter, overlay: FrontMatter) !void {
    if (self.set_arena == null)
        self.set_arena = std.heap.ArenaAllocator.init(self.allocator);
    try mergeJsonValue(self.set_arena.?.allocator(), &self.root, overlay.root);
}

// ── Field argument parsing ────────────────────────────────────────────────────

/// Parsed result of a `"key.path=value"` command-line argument.
/// Both `path` and any string `value.string` alias the original `arg` slice.
pub const FieldArg = struct {
    path: []const u8,
    value: std.json.Value,
};

/// Infer the JSON type of a raw string value (no allocation required).
///
/// Type precedence:
///   1. `"true"` / `"false"` → `.bool`
///   2. `"null"` → `.null`
///   3. Valid integer (no `.` in string) → `.integer`
///   4. Valid float (has `.` and parses) → `.float`
///   5. Everything else → `.string` (aliases `raw`)
pub fn inferValue(raw: []const u8) std.json.Value {
    if (std.mem.eql(u8, raw, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, raw, "false")) return .{ .bool = false };
    if (std.mem.eql(u8, raw, "null")) return .{ .null = {} };
    if (std.mem.indexOfScalar(u8, raw, '.') == null) {
        if (std.fmt.parseInt(i64, raw, 10)) |n| return .{ .integer = n } else |_| {}
    } else {
        if (std.fmt.parseFloat(f64, raw)) |f| return .{ .float = f } else |_| {}
    }
    return .{ .string = raw };
}

/// Parse a `"key.path=value"` argument into a `FieldArg`.
///
/// The `value` is type-inferred via `inferValue`; string values alias `arg`.
/// Returns `error.InvalidFieldArg` when there is no `=` or the path is empty.
pub fn parseFieldArg(arg: []const u8) error{InvalidFieldArg}!FieldArg {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.InvalidFieldArg;
    const path = arg[0..eq];
    if (path.len == 0) return error.InvalidFieldArg;
    return .{ .path = path, .value = inferValue(arg[eq + 1 ..]) };
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

// ── Serialization ─────────────────────────────────────────────────────────────

/// Serialize the frontmatter back to its original format, including delimiters.
///
/// | Format | Output                                         |
/// |--------|------------------------------------------------|
/// | YAML   | `---\nkey: val\n---\n`                         |
/// | TOML   | `+++\nkey = "val"\n+++\n`                      |
/// | JSON   | Pretty-printed JSON object followed by `\n`    |
/// | ZON    | `.{ .key = "val" }\n`                          |
///
/// Serialization always reflects the current state of `self.root`, so any
/// modifications made after parsing are included in the output.
///
/// The caller owns the returned slice; free with `alloc.free`.
pub fn serialize(self: FrontMatter, alloc: Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    switch (self.original) {
        .yaml => {
            try w.writeAll("---\n");
            try writeYamlValue(w, self.root, 0);
            try w.writeAll("---\n");
        },
        .toml => {
            try w.writeAll("+++\n");
            try writeTomlDocument(alloc, w, self.root);
            try w.writeAll("+++\n");
        },
        .json => {
            const json = try std.json.Stringify.valueAlloc(alloc, self.root, .{ .whitespace = .indent_2 });
            defer alloc.free(json);
            try w.writeAll(json);
            try w.writeByte('\n');
        },
        .zon => {
            try writeZonValue(w, self.root, 0);
            try w.writeByte('\n');
        },
    }
    return aw.toOwnedSlice();
}

/// Prepend the serialized frontmatter to `body` and return the full Markdown
/// document.  A single newline is inserted between the frontmatter block and
/// the body when `body` is non-empty and does not already start with `\n`.
///
/// The caller owns the returned slice; free with `alloc.free`.
pub fn toMarkdown(self: FrontMatter, alloc: Allocator, body: []const u8) ![]u8 {
    const fm_str = try self.serialize(alloc);
    defer alloc.free(fm_str);
    if (body.len == 0) return alloc.dupe(u8, fm_str);
    const sep: []const u8 = if (body[0] == '\n') "" else "\n";
    return std.mem.concat(alloc, u8, &.{ fm_str, sep, body });
}

// ── YAML emitter ──────────────────────────────────────────────────────────────

fn writeIndent(writer: anytype, level: usize) !void {
    var i: usize = 0;
    while (i < level * 2) : (i += 1) try writer.writeByte(' ');
}

/// Returns true if `s` must be wrapped in double quotes to be a valid YAML
/// plain scalar.
fn yamlNeedsQuote(s: []const u8) bool {
    if (s.len == 0) return true;
    for (&[_][]const u8{ "true", "false", "null", "yes", "no", "on", "off", "~" }) |kw| {
        if (std.ascii.eqlIgnoreCase(s, kw)) return true;
    }
    switch (s[0]) {
        '{', '}', '[', ']', ',', '#', '&', '*', '?', '|', '<', '>', '=', '!', '%', '@', '`', ':', '"', '\'', '\\' => return true,
        '-' => if (s.len == 1 or s[1] == ' ') return true,
        else => {},
    }
    for (s, 0..) |c, i| {
        switch (c) {
            '\n', '\r', '\t' => return true,
            ':' => if (i + 1 < s.len and (s[i + 1] == ' ' or s[i + 1] == '\n')) return true,
            '#' => if (i > 0 and s[i - 1] == ' ') return true,
            else => {},
        }
    }
    if (s[s.len - 1] == ':') return true;
    return false;
}

fn writeYamlString(writer: anytype, s: []const u8) !void {
    if (!yamlNeedsQuote(s)) {
        try writer.writeAll(s);
        return;
    }
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

/// Write the YAML representation of `value` at the given indent level.
/// For objects and arrays the output always ends with a newline; scalars do not
/// emit a trailing newline (the caller is responsible for that).
fn writeYamlValue(writer: anytype, value: std.json.Value, indent: usize) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |n| try writer.print("{d}", .{n}),
        .float => |f| try writer.print("{d}", .{f}),
        .number_string => |s| try writer.writeAll(s),
        .string => |s| try writeYamlString(writer, s),
        .array => |arr| {
            for (arr.items) |item| {
                try writeIndent(writer, indent);
                switch (item) {
                    .object, .array => {
                        try writer.writeAll("-\n");
                        try writeYamlValue(writer, item, indent + 1);
                    },
                    else => {
                        try writer.writeAll("- ");
                        try writeYamlValue(writer, item, indent);
                        try writer.writeByte('\n');
                    },
                }
            }
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                try writeIndent(writer, indent);
                try writer.writeAll(entry.key_ptr.*);
                switch (entry.value_ptr.*) {
                    .object, .array => {
                        try writer.writeAll(":\n");
                        try writeYamlValue(writer, entry.value_ptr.*, indent + 1);
                    },
                    else => {
                        try writer.writeAll(": ");
                        try writeYamlValue(writer, entry.value_ptr.*, 0);
                        try writer.writeByte('\n');
                    },
                }
            }
        },
    }
}

// ── TOML emitter ──────────────────────────────────────────────────────────────

fn isObjectArray(arr: std.json.Array) bool {
    for (arr.items) |item| {
        if (item == .object) return true;
    }
    return false;
}

fn writeTomlString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

/// Write a TOML scalar or inline array.  Objects are not handled here — they
/// appear as section headers, emitted by `writeTomlSection`.
fn writeTomlInline(writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("\"\""),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |n| try writer.print("{d}", .{n}),
        .float => |f| try writer.print("{d}", .{f}),
        .number_string => |s| try writer.writeAll(s),
        .string => |s| try writeTomlString(writer, s),
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeTomlInline(writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |obj| {
            // Inline table fallback — only reached for objects nested inside arrays.
            try writer.writeByte('{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try writer.writeAll(", ");
                first = false;
                try writer.writeAll(entry.key_ptr.*);
                try writer.writeAll(" = ");
                try writeTomlInline(writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
    }
}

/// Write the scalar/array key-value pairs of `obj` then recurse into sub-tables.
/// `prefix` is the dotted section path used to build `[prefix.subkey]` headers.
fn writeTomlSection(alloc: Allocator, writer: anytype, obj: std.json.ObjectMap, prefix: []const u8) !void {
    // Pass 1 — scalars and scalar arrays
    var it = obj.iterator();
    while (it.next()) |entry| {
        const v = entry.value_ptr.*;
        const is_table = v == .object or (v == .array and isObjectArray(v.array));
        if (!is_table) {
            try writer.writeAll(entry.key_ptr.*);
            try writer.writeAll(" = ");
            try writeTomlInline(writer, v);
            try writer.writeByte('\n');
        }
    }
    // Pass 2 — sub-tables and arrays of tables
    it = obj.iterator();
    while (it.next()) |entry| {
        const v = entry.value_ptr.*;
        const sub = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ prefix, entry.key_ptr.* });
        defer alloc.free(sub);
        if (v == .object) {
            try writer.print("\n[{s}]\n", .{sub});
            try writeTomlSection(alloc, writer, v.object, sub);
        } else if (v == .array and isObjectArray(v.array)) {
            for (v.array.items) |item| {
                if (item != .object) continue;
                try writer.print("\n[[{s}]]\n", .{sub});
                try writeTomlSection(alloc, writer, item.object, sub);
            }
        }
    }
}

fn writeTomlDocument(alloc: Allocator, writer: anytype, root: std.json.Value) !void {
    if (root != .object) return;
    const obj = root.object;
    // Pass 1 — top-level scalars and scalar arrays
    var it = obj.iterator();
    while (it.next()) |entry| {
        const v = entry.value_ptr.*;
        const is_table = v == .object or (v == .array and isObjectArray(v.array));
        if (!is_table) {
            try writer.writeAll(entry.key_ptr.*);
            try writer.writeAll(" = ");
            try writeTomlInline(writer, v);
            try writer.writeByte('\n');
        }
    }
    // Pass 2 — [section] and [[array-of-tables]]
    it = obj.iterator();
    while (it.next()) |entry| {
        const v = entry.value_ptr.*;
        if (v == .object) {
            try writer.print("\n[{s}]\n", .{entry.key_ptr.*});
            try writeTomlSection(alloc, writer, v.object, entry.key_ptr.*);
        } else if (v == .array and isObjectArray(v.array)) {
            for (v.array.items) |item| {
                if (item != .object) continue;
                try writer.print("\n[[{s}]]\n", .{entry.key_ptr.*});
                try writeTomlSection(alloc, writer, item.object, entry.key_ptr.*);
            }
        }
    }
}

// ── ZON emitter ───────────────────────────────────────────────────────────────

fn writeZonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn writeZonValue(writer: anytype, value: std.json.Value, indent: usize) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |n| try writer.print("{d}", .{n}),
        .float => |f| try writer.print("{d}", .{f}),
        .number_string => |s| try writer.writeAll(s),
        .string => |s| try writeZonString(writer, s),
        .array => |arr| {
            try writer.writeAll(".{\n");
            for (arr.items) |item| {
                try writeIndent(writer, indent + 1);
                try writeZonValue(writer, item, indent + 1);
                try writer.writeAll(",\n");
            }
            try writeIndent(writer, indent);
            try writer.writeByte('}');
        },
        .object => |obj| {
            try writer.writeAll(".{\n");
            var it = obj.iterator();
            while (it.next()) |entry| {
                try writeIndent(writer, indent + 1);
                try writer.writeByte('.');
                try writer.writeAll(entry.key_ptr.*);
                try writer.writeAll(" = ");
                try writeZonValue(writer, entry.value_ptr.*, indent + 1);
                try writer.writeAll(",\n");
            }
            try writeIndent(writer, indent);
            try writer.writeByte('}');
        },
    }
}

// tera integration test moved to the standalone tera package

test {
    _ = @import("frontmatter_test.zig");
}
