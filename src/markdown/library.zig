//! Library node — a queryable collection of parsed Markdown documents.
//!
//! A `Library` holds zero or more `Entry` values, each pairing an
//! `AST.Document` with its optional `FrontMatter` and an optional path
//! identifier.  Documents without frontmatter are fully supported.
//!
//! ## Building a library
//!
//! ```zig
//! var lib = Library.init(allocator);
//! defer lib.deinit();
//!
//! try lib.add(source, "policies/access-control.md");  // in-memory
//! try lib.addFromFile("policies/hr.md");              // read from disk
//! try lib.addFromDir("policies/");                    // recursively load *.md
//! ```
//!
//! ## Query syntax
//!
//! `Library.query` accepts a whitespace-separated string of tokens:
//!
//! | Token            | Meaning                                              |
//! |------------------|------------------------------------------------------|
//! | `path`           | frontmatter field at `path` must exist               |
//! | `path=value`     | frontmatter field at `path` must equal `value`       |
//! | `@block_type`    | select blocks of this type from matching documents   |
//!
//! Multiple `path` / `path=value` tokens are **AND-combined**: a document
//! must satisfy every filter to appear in the results.
//!
//! The dot-path syntax is identical to `FrontMatter.get/set` (e.g.
//! `"extra.owner"`, `"taxonomies.TSC2017"`).  Block type names match the
//! `AST.Block` union field names (`heading`, `paragraph`, `code_block`,
//! `fenced_code_block`, `blockquote`, `list`, `table`, …).
//!
//! ### Examples
//!
//! ```
//! "title"                              → docs where frontmatter.title exists
//! "extra.owner=SC2"                    → docs where extra.owner == "SC2"
//! "extra.owner=SC2 extra.category=sec" → docs matching BOTH filters (AND)
//! "@heading"                           → every heading across all documents
//! "taxonomies.TSC2017 @heading"        → headings from docs with that taxonomy
//! "extra.owner=SC2 @code_block"        → code blocks from SC2-owned docs
//! ```
//!
//! Without a `@block_type` token one result per matching document is returned
//! with `block = null`.
//!
//! ## Sorting results
//!
//! After calling `query`, sort results in-place with `Library.sortBy`:
//!
//! ```zig
//! const results = try lib.query(allocator, "title") orelse return;
//! defer allocator.free(results);
//! Library.sortBy(results, "title", true); // ascending
//! ```
//!
//! ## Confidence
//!
//! Results are sorted by confidence (descending).  Current scoring:
//!
//! * `1.0` — exact frontmatter match (or no frontmatter filter)
//! * `0.0` — no match (excluded from results)
//!
//! Fractional confidence values are reserved for future fuzzy / semantic
//! matching extensions.
const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;

const AST = @import("ast.zig");
const Frontmatter = @import("frontmatter.zig");
const Parser = @import("parser.zig");

/// A queryable collection of parsed Markdown documents with frontmatter.
pub const Library = struct {
    allocator: Allocator,
    entries: std.ArrayList(Entry),

    // ── Public types ──────────────────────────────────────────────────────────

    /// A single document in the library, paired with its (optional) frontmatter
    /// and an optional path identifier.
    pub const Entry = struct {
        document: AST.Document,
        /// `null` when the source had no recognisable frontmatter block.
        frontmatter: ?Frontmatter,
        /// Optional filesystem path or logical identifier, owned by this entry.
        path: ?[]const u8,
        /// Wyhash of the raw source bytes.  Useful for change detection when
        /// watching a directory: compare against a stored hash to know whether
        /// a file needs to be re-added.
        content_hash: u64,

        pub fn deinit(self: *Entry, allocator: Allocator) void {
            self.document.deinit(allocator);
            if (self.frontmatter) |*fm| fm.deinit();
            if (self.path) |p| allocator.free(p);
        }
    };

    /// A single query result: the matching entry, an optional block within
    /// that entry, and a confidence score in [0.0, 1.0].
    ///
    /// **Lifetime:** `entry` and `block` are non-owning pointers into the
    /// `Library`.  Do not use them after the `Library` (or its entries) has
    /// been modified or freed.
    pub const Result = struct {
        entry: *const Entry,
        /// The specific block that matched, or `null` for a document-level
        /// match (no `@block_type` token in the query).
        block: ?*const AST.Block,
        /// Confidence of the match: `1.0` for exact, lower for partial.
        confidence: f32,
    };

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    pub fn init(allocator: Allocator) Library {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(Entry){},
        };
    }

    pub fn deinit(self: *Library) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    // ── Mutation ──────────────────────────────────────────────────────────────

    /// Parse `source` and add the resulting document to the library.
    ///
    /// `path` is an optional identifier (e.g. a filesystem path); it is
    /// duplicated and owned by the entry.  Pass `null` for anonymous documents.
    ///
    /// Documents without frontmatter are accepted: `entry.frontmatter` will
    /// be `null` for those entries.
    pub fn add(self: *Library, source: []const u8, path: ?[]const u8) !void {
        var parser = Parser.init();
        var doc = try parser.parseMarkdown(self.allocator, source);
        errdefer doc.deinit(self.allocator);

        var fm: ?Frontmatter = Frontmatter.initFromMarkdown(self.allocator, source) catch |err| switch (err) {
            error.InvalidFrontMatter => null,
            else => return err,
        };
        errdefer if (fm) |*f| f.deinit();

        const owned_path = if (path) |p| try self.allocator.dupe(u8, p) else null;
        errdefer if (owned_path) |p| self.allocator.free(p);

        try self.entries.append(self.allocator, .{
            .document = doc,
            .frontmatter = fm,
            .path = owned_path,
            .content_hash = std.hash.Wyhash.hash(0, source),
        });
    }

    /// Read the Markdown file at `path` and add it to the library.
    ///
    /// `path` may be absolute or relative to the process working directory.
    /// It is stored verbatim as the entry's path identifier.
    /// Files up to 16 MiB are supported.
    pub fn addFromFile(self: *Library, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const source = try file.readToEndAlloc(self.allocator, 16 * 1024 * 1024);
        defer self.allocator.free(source);
        try self.add(source, path);
    }

    /// Recursively add all `*.md` files under `dir_path` to the library.
    ///
    /// `dir_path` may be absolute or relative to the process working directory.
    /// Each entry's path identifier is formed by joining `dir_path` with the
    /// file's path relative to `dir_path` (e.g. `"policies/hr/hr-policy.md"`).
    /// Non-`.md` files are silently skipped; subdirectories are traversed.
    pub fn addFromDir(self: *Library, dir_path: []const u8) !void {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |wentry| {
            if (wentry.kind != .file) continue;
            if (!mem.endsWith(u8, wentry.basename, ".md")) continue;

            var file = try wentry.dir.openFile(wentry.basename, .{});
            defer file.close();

            const source = try file.readToEndAlloc(self.allocator, 16 * 1024 * 1024);
            defer self.allocator.free(source);

            const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, wentry.path });
            defer self.allocator.free(full_path);

            try self.add(source, full_path);
        }
    }

    // ── Query ─────────────────────────────────────────────────────────────────

    /// Execute a query against all documents in the library.
    ///
    /// Returns `null` when there are no matches.  Otherwise returns an owned
    /// slice of `Result` values sorted by confidence (descending).
    ///
    /// The caller must free the returned slice with `allocator.free(slice)`.
    /// The `entry` and `block` pointers inside each result remain valid as
    /// long as this `Library` is alive and unmodified.
    ///
    /// See the module doc-comment for the query syntax.
    pub fn query(self: *const Library, allocator: Allocator, q: []const u8) !?[]Result {
        const pq = parseQuery(q);
        return executeQuery(self, allocator, pq);
    }

    /// Sort `results` in-place by a frontmatter field value.
    ///
    /// String fields are compared lexicographically; integer and float fields
    /// are compared numerically.  Results whose entry lacks `field`, or whose
    /// field value is not a comparable scalar (bool, array, object), sort last.
    ///
    /// Pass `ascending = true` for smallest-first order, `false` for
    /// largest-first.
    pub fn sortBy(results: []Result, field: []const u8, ascending: bool) void {
        const Ctx = struct {
            field: []const u8,
            ascending: bool,
            fn lt(ctx: @This(), a: Result, b: Result) bool {
                const va = fieldJsonValue(a.entry, ctx.field);
                const vb = fieldJsonValue(b.entry, ctx.field);
                const ord = compareJsonScalar(va, vb);
                return if (ctx.ascending) ord == .lt else ord == .gt;
            }
        };
        mem.sort(Result, results, Ctx{ .field = field, .ascending = ascending }, Ctx.lt);
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    /// A single frontmatter filter derived from one `path` or `path=value`
    /// token in the query string.
    const Filter = struct {
        path: []const u8,
        /// `null` → field must exist (any value accepted).
        /// Non-null → field value must match this string.
        value: ?[]const u8,
    };

    const max_filters = 16;

    const ParsedQuery = struct {
        /// AND-combined frontmatter filters.  All must match for a document
        /// to be included in the results.  Capacity of 16 covers all
        /// realistic queries.
        filters: [max_filters]Filter = undefined,
        filter_count: u8 = 0,
        /// Resolved block type tag to select.
        /// `null` when no `@` token was present (doc-level results).
        block_tag: ?std.meta.Tag(AST.Block) = null,
        /// True when a `@block_type` token was present, even if unrecognised.
        /// When true and `block_tag == null` the query can never match anything.
        has_block_selector: bool = false,

        fn filtersSlice(self: *const ParsedQuery) []const Filter {
            return self.filters[0..self.filter_count];
        }

        fn appendFilter(self: *ParsedQuery, f: Filter) void {
            if (self.filter_count < max_filters) {
                self.filters[self.filter_count] = f;
                self.filter_count += 1;
            }
        }
    };

    fn parseQuery(q: []const u8) ParsedQuery {
        var result = ParsedQuery{};
        var it = mem.tokenizeAny(u8, q, " \t");
        while (it.next()) |token| {
            if (mem.startsWith(u8, token, "@")) {
                result.has_block_selector = true;
                result.block_tag = std.meta.stringToEnum(std.meta.Tag(AST.Block), token[1..]);
            } else if (mem.indexOf(u8, token, "=")) |eq| {
                result.appendFilter(.{ .path = token[0..eq], .value = token[eq + 1 ..] });
            } else if (token.len > 0) {
                result.appendFilter(.{ .path = token, .value = null });
            }
        }
        return result;
    }

    /// Recursively collect all blocks matching `tag` at any nesting depth
    /// (top-level, inside blockquotes, inside list items, inside footnote
    /// definitions) and append them to `out`.
    fn collectByTag(
        allocator: Allocator,
        blocks: []AST.Block,
        tag: std.meta.Tag(AST.Block),
        entry: *const Entry,
        confidence: f32,
        out: *std.ArrayList(Result),
    ) !void {
        for (blocks) |*block| {
            if (std.meta.activeTag(block.*) == tag) {
                try out.append(allocator, .{
                    .entry = entry,
                    .block = block,
                    .confidence = confidence,
                });
            }
            // Recurse into container blocks regardless of whether the container
            // itself matched, so nested blocks are never silently skipped.
            switch (block.*) {
                .blockquote => |*bq| try collectByTag(allocator, bq.children.items, tag, entry, confidence, out),
                .list => |*l| for (l.items.items) |*item| {
                    try collectByTag(allocator, item.children.items, tag, entry, confidence, out);
                },
                .footnote_definition => |*fd| try collectByTag(allocator, fd.children.items, tag, entry, confidence, out),
                else => {},
            }
        }
    }

    fn executeQuery(self: *const Library, allocator: Allocator, pq: ParsedQuery) !?[]Result {
        var results = std.ArrayList(Result){};
        errdefer results.deinit(allocator);

        for (self.entries.items) |*entry| {
            const confidence = matchFrontmatter(entry, pq.filtersSlice());
            if (confidence == 0.0) continue;

            if (pq.block_tag) |tag| {
                try collectByTag(allocator, entry.document.children.items, tag, entry, confidence, &results);
            } else if (!pq.has_block_selector) {
                // No `@block_type` token at all — emit a doc-level result.
                try results.append(allocator, .{
                    .entry = entry,
                    .block = null,
                    .confidence = confidence,
                });
            }
            // has_block_selector but block_tag == null means unrecognised type:
            // no results for this entry.
        }

        if (results.items.len == 0) {
            results.deinit(allocator);
            return null;
        }

        mem.sort(Result, results.items, {}, struct {
            fn lt(_: void, a: Result, b: Result) bool {
                return a.confidence > b.confidence;
            }
        }.lt);

        return try results.toOwnedSlice(allocator);
    }

    fn matchFrontmatter(entry: *const Entry, filters: []const Filter) f32 {
        if (filters.len == 0) return 1.0;
        for (filters) |f| {
            const fm = entry.frontmatter orelse return 0.0;
            const json_val = fm.get(f.path) orelse return 0.0;
            if (f.value) |expected| {
                if (!jsonValueMatchesString(json_val, expected)) return 0.0;
            }
        }
        return 1.0;
    }

    fn jsonValueMatchesString(value: std.json.Value, expected: []const u8) bool {
        return switch (value) {
            .string => |s| mem.eql(u8, s, expected),
            .bool => |b| mem.eql(u8, if (b) "true" else "false", expected),
            .null => mem.eql(u8, expected, "null"),
            .integer => |n| blk: {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch break :blk false;
                break :blk mem.eql(u8, s, expected);
            },
            .float => |f| blk: {
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch break :blk false;
                break :blk mem.eql(u8, s, expected);
            },
            // Array: true if any element matches (containment check).
            // This is the common case for taxonomy fields like:
            //   taxonomies.SCF=HRS-05  where SCF is ["HRS-05", "HRS-05.1"]
            .array => |arr| for (arr.items) |item| {
                if (jsonValueMatchesString(item, expected)) break true;
            } else false,
            else => false,
        };
    }

    fn fieldJsonValue(entry: *const Entry, field: []const u8) ?std.json.Value {
        const fm = entry.frontmatter orelse return null;
        return fm.get(field);
    }

    /// Compare two optional JSON scalar values for sort ordering.
    /// Missing fields (`null`) always sort last.
    /// Cross-type ordering: string/integer/float before bool/array/object/null.
    fn compareJsonScalar(a: ?std.json.Value, b: ?std.json.Value) std.math.Order {
        if (a == null and b == null) return .eq;
        if (a == null) return .gt; // missing sorts last
        if (b == null) return .lt;
        return switch (a.?) {
            .string => |sa| switch (b.?) {
                .string => |sb| mem.order(u8, sa, sb),
                else => .lt,
            },
            .integer => |ia| switch (b.?) {
                .integer => |ib| std.math.order(ia, ib),
                .float => |fb| std.math.order(@as(f64, @floatFromInt(ia)), fb),
                else => .lt,
            },
            .float => |fa| switch (b.?) {
                .float => |fb| std.math.order(fa, fb),
                .integer => |ib| std.math.order(fa, @as(f64, @floatFromInt(ib))),
                else => .lt,
            },
            else => .gt, // bool, null, array, object sort last
        };
    }
};
