# zigmark

[![CI](https://github.com/sc2in/zigmark/actions/workflows/ci.yml/badge.svg)](https://github.com/sc2in/zigmark/actions/workflows/ci.yml)

A CommonMark-compliant Markdown parser and renderer for Zig. Passes **all 652 CommonMark spec tests** and **all 24 GFM extension tests** (100%).

Renders to **HTML**, **Typst** (PDF-ready), **AST**, and more.

Builds as both a **CLI tool** and a **C-callable shared library** (`libzigmark.so`).

## Installation

Add `zigmark` as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .zigmark = .{
        .url = "https://github.com/sc2in/zigmark/archive/<commit>.tar.gz",
        .hash = "...",
    },
}
```

Then in your `build.zig`:

```zig
const zigmark = b.dependency("zigmark", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zigmark", zigmark.module("zigmark"));
```

## CLI Usage

```bash
zig build
```

### Convert Markdown to HTML

```bash
# From a file
zigmark README.md

# From stdin
echo '# Hello' | zigmark

# Write to a file
zigmark -o output.html README.md
```

### Inspect the AST

```bash
echo '**bold** and *italic*' | zigmark -f ast
```

```
Document
└── Paragraph
    ├── Strong ('*')
    │   └── Text "bold"
    ├── Text " and "
    └── Emphasis ('*')
        └── Text "italic"
```

### Convert Markdown to Typst (PDF)

```bash
# Body-only Typst markup (embed in your own document)
echo '# Hello' | zigmark -f typst

# Full document with eisvogel-inspired preamble — pipe straight to typst
zigmark -f typst report.md | typst compile - report.pdf
```

YAML frontmatter fields are automatically mapped to document options:

```markdown
---
title: "My Report"
author: Alice
date: 2026-03-19
titlepage: true
toc: true
numbersections: true
colorlinks: true
header-right: "Confidential"
footer-left: "Alice"
---

# Introduction

Hello **world**.
```

Supported frontmatter fields:

| Field | Type | Default | Description |
|---|---|---|---|
| `title` | string | — | Document title |
| `subtitle` | string | — | Subtitle shown on title page |
| `author` | string or list | — | Author name(s); list uses the first entry |
| `date` | string | — | Date shown on title page |
| `lang` | string | `en` | Document language |
| `paper` | string | `a4` | Paper size (e.g. `a4`, `us-letter`) |
| `fontsize` | string | `11pt` | Base font size |
| `titlepage` | bool | `false` | Generate a full-bleed title page |
| `titlepage-color` | string | `1E3A5F` | Title page background (hex, no `#`) |
| `titlepage-text-color` | string | `FFFFFF` | Title page text colour |
| `titlepage-rule-color` | string | `AAAAAA` | Title page rule colour |
| `titlepage-rule-height` | number | `4` | Title page rule thickness (pt) |
| `toc` | bool | `false` | Insert a table of contents |
| `toc-title` | string | `Contents` | TOC heading |
| `toc-own-page` | bool | `false` | *(reserved, not yet implemented)* |
| `toc-depth` | number | `3` | TOC depth |
| `numbersections` | bool | `false` | Number headings |
| `disable-header-and-footer` | bool | `false` | Suppress page header and footer |
| `header-left` / `header-center` / `header-right` | string | title / — / date | Header slots |
| `footer-left` / `footer-center` / `footer-right` | string | author / — / page\# | Footer slots |
| `colorlinks` | bool | `true` | Colour hyperlinks |
| `linkcolor` | string | `A50000` | Internal link colour (hex) |
| `urlcolor` | string | `4077C0` | URL link colour (hex) |

### AI-Friendly Output

```bash
zigmark -f ai README.md
```

Produces a token-efficient AST representation suitable for LLM consumption.

### Extract Frontmatter as JSON

```bash
zigmark -f frontmatter post.md
```

Parses the frontmatter block (YAML `---`, TOML `+++`, JSON `{`, or ZON `.{`) and
emits it as pretty-printed JSON.  Outputs `{}` when no frontmatter is present,
so the output is always valid JSON and safe to pipe.

```bash
# Pipe into jq
zigmark -f frontmatter post.md | jq '.title'

# Extract a nested key
zigmark -f frontmatter post.md | jq '.extra.author'
```

### Edit Frontmatter

`--format markdown` re-serialises the frontmatter (in its original format) and
passes the body through verbatim.  Use `--set` and `--delete` to mutate fields
before writing:

```bash
# Update a field and delete another, keep body unchanged
zigmark -f markdown --set title="New Title" --delete draft post.md

# Set a nested key (intermediate objects are created automatically)
zigmark -f markdown --set extra.owner=SC2 post.md

# Pipe the result back over the original file
zigmark -f markdown --set date=2025-06-01 post.md -o post.md
```

`--format normalize` does the same frontmatter handling but also reconstructs
the Markdown body from the AST, normalising headings to ATX style, links to
inline, and code blocks to fenced:

```bash
zigmark -f normalize --set title="Clean" post.md
```

### Edit Body Blocks

`--set-block` replaces a single block in the document body using a
`type[N]` selector — the same bracket syntax used by the AST query API.
`type` is any block tag (`block`, `heading`, `paragraph`, `table`, …);
`N` is a zero-based index.  The right-hand side is parsed as Markdown and
its first block becomes the replacement.  Applies to `normalize` format.

```bash
# Replace the first heading
zigmark -f normalize --set-block 'heading[0]=# New Title' post.md

# Replace a block at an absolute index (any type)
zigmark -f normalize --set-block 'block[3]=Updated paragraph text.' post.md

# Replace the second table
zigmark -f normalize --set-block 'table[1]=| A | B |\n|---|---|\n| 1 | 2 |' post.md

# Combine with frontmatter edits
zigmark -f normalize --set title="Clean" --set-block 'heading[0]=# Clean' post.md -o post.md
```

`--section-start` and `--section-end` replace every block *between* two
HTML comment markers (the markers themselves are preserved).  Replacement
Markdown is read from stdin; the document file must be given as a
positional argument.  Applies to `normalize` format.

```bash
# Replace the content between <!-- bench-start --> and <!-- bench-end -->
cat new-perf-tables.md | zigmark -f normalize \
  --section-start bench-start \
  --section-end   bench-end   \
  README.md -o README.md
```

This is how `nix run .#bench` updates the performance section of this
README — it generates the new table Markdown, then uses zigmark's own AST
mutation API to splice it in, replacing the Python regex that did the same
job before.

### Options

```
Usage: zigmark [OPTIONS] [FILE]

  -h, --help                  Display this help and exit.
  -v, --version               Print version and exit.
  -f, --format <str>          Output format: "html" (default), "typst", "ast",
                              "ai", "terminal", "frontmatter", "markdown", or
                              "normalize".
  -o, --output <str>          Write output to FILE instead of stdout.
  -s, --set <str>...          Set a frontmatter field (KEY=VALUE). Repeatable.
                              Applies to: markdown, normalize, frontmatter.
  -d, --delete <str>...       Delete a frontmatter field (dot-path). Repeatable.
                              Applies to: markdown, normalize, frontmatter.
  -e, --set-block <str>...    Edit a body block (SELECTOR=CONTENT). Selectors:
                              block[N], heading[N], paragraph[N], table[N].
                              First block of CONTENT replaces the target.
                              Repeatable. Applies to: normalize.
      --section-start <str>   ) Replace document body between two HTML comment
      --section-end   <str>   ) markers with Markdown from stdin. FILE required.
                                Applies to: normalize.
```

## Zig Library Usage

### Basic Parsing and Rendering

```zig
const std = @import("std");
const zigmark = @import("zigmark");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const markdown =
        \\# Hello World
        \\
        \\This is a **bold** paragraph with a [link](https://sc2.in).
        \\
        \\- List item 1
        \\- List item 2
    ;

    var parser = zigmark.Parser.init();
    var doc = try parser.parseMarkdown(allocator, markdown);
    defer doc.deinit(allocator);

    const html = try zigmark.HTMLRenderer.render(allocator, doc);
    defer allocator.free(html);

    std.debug.print("{s}\n", .{html});
}
```

### Typst Rendering

Generate Typst markup from a parsed document:

```zig
const zigmark = @import("zigmark");

// Body-only (embed in your own Typst document)
const markup = try zigmark.TypstRenderer.render(allocator, doc);
defer allocator.free(markup);

// Full document with eisvogel-inspired preamble
const opts = zigmark.typst.DocumentOptions{
    .title          = "My Report",
    .author         = "Alice",
    .date           = "2026-03-19",
    .titlepage      = true,
    .toc            = true,
    .numbersections = true,
    .colorlinks     = true,
};
const full = try zigmark.typst.renderDocument(allocator, doc, opts);
defer allocator.free(full);
```

### AST Query System

Navigate the parsed document with jQuery-like selectors:

```zig
var query = doc.get();

// Get all headings (optionally filter by level)
var headings = try query.headings(allocator, null);
var h2s = try query.headings(allocator, 2);

// Get all links
var links = try query.links(allocator);

// Count elements
const para_count = query.count(.paragraph);
```

### Frontmatter

Extract and query structured metadata from the top of a Markdown file.  All four formats are normalised to `std.json.Value` for uniform access.

| Format | Opening marker | Example |
|---|---|---|
| YAML | `---` | `--- \ntitle: Hello\n---` |
| TOML | `+++` | `+++\ntitle = "Hello"\n+++` |
| JSON | `{` | `{"title": "Hello"}` |
| ZON | `.{` | `.{ .title = "Hello" }` |

```zig
const FrontMatter = zigmark.FrontMatter;

// Parse from a full Markdown document (auto-detects format)
var fm = try FrontMatter.initFromMarkdown(allocator, markdown_source);
defer fm.deinit();

// Dot-separated key lookup — returns ?std.json.Value
const title  = fm.get("title");            // top-level key
const host   = fm.get("server.host");      // nested key
const first  = fm.get("tags");             // array → .array variant

if (title) |t| std.debug.print("title: {s}\n", .{t.string});

// Or parse a bare frontmatter string directly
var fm2 = try FrontMatter.init(allocator, source, .toml);
defer fm2.deinit();

// Mutate: set a value at a dot-separated path (creates intermediates as needed)
try fm.set("title", .{ .string = "New Title" });
try fm.set("extra.owner", .{ .string = "SC2" });
try fm.set("draft", .{ .bool = false });

// Delete a key
_ = fm.delete("draft");

// Deep-merge another frontmatter document (overlay keys win on conflict)
var overlay = try FrontMatter.initFromMarkdown(allocator, other_source);
defer overlay.deinit();
try fm.merge(overlay);

// Re-serialise in the original format (YAML/TOML/JSON/ZON)
const serialized = try fm.serialize(allocator);
defer allocator.free(serialized);
```

ZON frontmatter supports the full frontmatter subset: anonymous structs, array tuples, strings (with escape sequences), integers (decimal / hex / octal / binary), floats, booleans, `null`, and enum literals (returned as strings).

```zig
// ZON example
const source =
    \\.{
    \\    .title   = "My Post",
    \\    .tags    = .{ "zig", "wasm" },
    \\    .draft   = false,
    \\    .weight  = 10,
    \\    .status  = .published,   // enum literal → "published"
    \\}
;
var fm = try FrontMatter.init(allocator, source, .zon);
defer fm.deinit();
```

### Library

A `Library` holds a collection of parsed Markdown documents with their frontmatter and lets you query across all of them using an extended dot-syntax.

```zig
const Library = zigmark.Library;

var lib = Library.init(allocator);
defer lib.deinit();

// In-memory: path is an optional identifier
try lib.add(source_a, "policies/access-control.md");
try lib.add(source_b, null); // anonymous document

// From disk: path is stored as the entry identifier
try lib.addFromFile("policies/hr.md");

// Recursively load all *.md files under a directory
try lib.addFromDir("policies/");

// Query returns ?[]Library.Result — null when nothing matches.
// Caller frees the slice; entry/block pointers are valid while the Library lives.
const results = try lib.query(allocator, "extra.owner=SC2 @heading") orelse return;
defer allocator.free(results);

for (results) |r| {
    std.debug.print("path: {?s}  confidence: {d:.1}\n", .{ r.entry.path, r.confidence });
    if (r.block) |b| {
        std.debug.print("  heading level {d}\n", .{b.heading.level});
    }
}

// Sort results in-place by a frontmatter field (ascending or descending)
Library.sortBy(results, "title", true);
```

#### Query syntax

Tokens are whitespace-separated and may appear in any order.

| Token | Meaning |
|---|---|
| `path` | frontmatter field at `path` must exist |
| `path=value` | frontmatter field at `path` must equal `value` |
| `@block_type` | select blocks of this type from matching documents |

Multiple `path` / `path=value` tokens are **AND-combined**: a document must satisfy every filter to appear in results.

The dot-path syntax is identical to `Frontmatter` (`"title"`, `"extra.owner"`, `"taxonomies.SCF"`).  Block type names match the `AST.Block` union tags (`heading`, `paragraph`, `code_block`, `fenced_code_block`, `blockquote`, `list`, `table`, …).

Without a `@block_type` token, one result per matching document is returned with `result.block == null`.

#### Examples

```zig
// All documents that have a title field
try lib.query(allocator, "title")

// Documents owned by SC2
try lib.query(allocator, "extra.owner=SC2")

// Documents owned by SC2 in the security category (AND filter)
try lib.query(allocator, "extra.owner=SC2 extra.category=security")

// Every heading across every document in the library
try lib.query(allocator, "@heading")

// Headings only from SC2-owned documents
try lib.query(allocator, "extra.owner=SC2 @heading")

// Fenced code blocks from documents tagged with a specific taxonomy entry
try lib.query(allocator, "taxonomies.SCF @fenced_code_block")
```

#### Result fields

| Field | Type | Description |
|---|---|---|
| `entry` | `*const Library.Entry` | The matching document (`.document`, `.frontmatter`, `.path`) |
| `block` | `?*const AST.Block` | The specific block that matched, or `null` for doc-level results |
| `confidence` | `f32` | Match confidence in `[0.0, 1.0]`; results sorted descending |

Documents without frontmatter are supported — they simply never match frontmatter filters.

#### Sorting

`Library.sortBy` sorts a result slice in-place by a frontmatter field value.  String fields are compared lexicographically; integer and float fields are compared numerically.  Results missing the field sort last.

```zig
// Sort by title A→Z
Library.sortBy(results, "title", true);

// Sort by date newest-first
Library.sortBy(results, "date", false);
```

### Streaming / Large Documents

For large documents, avoid building a full output string with `renderToWriter`, which writes directly to any `*std.Io.Writer`:

```zig
var out_buf: [8192]u8 = undefined;
var writer = file.writer(&out_buf);

// Render directly to a file — no intermediate allocation
try zigmark.HTMLRenderer.renderToWriter(allocator, &writer.interface, doc);
try writer.interface.flush();
```

All six built-in renderers (`HTMLRenderer`, `ASTRenderer`, `AIRenderer`, `TerminalRenderer`, `MarkdownRenderer`, `TypstRenderer`) expose `renderToWriter`.  The Typst full-document variant is `zigmark.typst.renderDocumentToWriter`.

To parse from a stream (file, stdin, pipe, socket) without a `readToEndAlloc` call:

```zig
var read_buf: [4096]u8 = undefined;
var reader = file.reader(&read_buf);

var parser = zigmark.Parser.init();
var doc = try parser.parseFromReader(allocator, &reader.interface);
defer doc.deinit(allocator);
```

The returned `AST.Document` is fully self-contained — no external buffer needs to outlive it.

### Custom Renderers

Implement both `render` and `renderToWriter` to satisfy the `Renderer` interface:

```zig
pub fn render(allocator: Allocator, doc: AST.Document) ![]u8 { ... }
pub fn renderToWriter(allocator: Allocator, writer: *std.Io.Writer, doc: AST.Document) !void { ... }

const MyRenderer = zigmark.Renderer.create(my_backend);
const output = try MyRenderer.render(allocator, doc);
try MyRenderer.renderToWriter(allocator, &writer.interface, doc);
```

## C Shared Library

The build produces `libzigmark.so` and `include/zigmark.h` — a self-contained shared library with no libc dependency.

### C API

```c
#include "zigmark.h"

ZigmarkDocument  *zigmark_parse(const char *input, size_t len);
void              zigmark_free_document(ZigmarkDocument *doc);

char             *zigmark_render_html(ZigmarkDocument *doc);
char             *zigmark_render_ast(ZigmarkDocument *doc);
char             *zigmark_render_ai(ZigmarkDocument *doc);
void              zigmark_free_string(char *str);

const char       *zigmark_version(void);

/* Frontmatter */
ZigmarkFrontmatter *zigmark_frontmatter_parse(const char *input, size_t len);
void                zigmark_frontmatter_free(ZigmarkFrontmatter *fm);
char               *zigmark_frontmatter_to_json(ZigmarkFrontmatter *fm);
char               *zigmark_frontmatter_get(ZigmarkFrontmatter *fm, const char *key);
char               *zigmark_frontmatter_serialize(ZigmarkFrontmatter *fm);
int                 zigmark_frontmatter_merge(ZigmarkFrontmatter *base, ZigmarkFrontmatter *overlay);
int                 zigmark_frontmatter_set(ZigmarkFrontmatter *fm, const char *path, const char *json_value);
int                 zigmark_frontmatter_set_raw(ZigmarkFrontmatter *fm, const char *path, const char *raw);
```

### Example

```c
#include <stdio.h>
#include "zigmark.h"

int main(void) {
    const char *md = "# Hello\n\nWorld.";
    ZigmarkDocument *doc = zigmark_parse(md, 15);
    if (!doc) return 1;

    char *html = zigmark_render_html(doc);
    if (html) { printf("%s", html); zigmark_free_string(html); }

    zigmark_free_document(doc);
    return 0;
}
```

### Compile and Link

```bash
zig build -Doptimize=ReleaseSafe
zig cc -o example example.c -Izig-out/include -Lzig-out/lib -lzigmark
LD_LIBRARY_PATH=zig-out/lib ./example
```

## Features

### CommonMark Compliance — 652/652 ✅

Every section of the [CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/) spec passes:

| Section | Tests |
|---|---|
| Tabs | 11 |
| Backslash escapes | 13 |
| Entity and numeric character references | 17 |
| Precedence | 1 |
| Thematic breaks | 19 |
| ATX headings | 18 |
| Setext headings | 27 |
| Indented code blocks | 12 |
| Fenced code blocks | 29 |
| HTML blocks | 44 |
| Link reference definitions | 27 |
| Paragraphs | 8 |
| Blank lines | 1 |
| Block quotes | 25 |
| List items | 48 |
| Lists | 27 |
| Code spans | 22 |
| Emphasis and strong emphasis | 132 |
| Links | 90 |
| Images | 22 |
| Autolinks | 19 |
| Raw HTML | 20 |
| Hard line breaks | 15 |
| Soft line breaks | 2 |
| Textual content | 3 |

### GFM Extensions — 24/24 ✅

All [GitHub Flavored Markdown](https://github.github.com/gfm/) extensions pass.

| GFM Extension | Tests |
|---|---|
| Tables | 8/8 ✅ |
| Task list items | 2/2 ✅ |
| Strikethrough | 2/2 ✅ |
| Autolinks (extended) | 11/11 ✅ |
| Disallowed raw HTML | 1/1 ✅ |

**Tables** — pipe-delimited with column alignment (`---`, `:---`, `---:`, `:---:`):

```markdown
| Name    | Role     | Score |
| ------- | -------- | ----: |
| Alice   | Engineer |    42 |
| Bob     | Designer |    37 |
```

**Task lists** — checked and unchecked items render as disabled checkboxes:

```markdown
- [x] Done
- [ ] Not done
```

**Strikethrough** — `~~text~~` renders as `<del>text</del>`:

```markdown
~~deleted text~~
```

**Extended autolinks** — bare `www.` links, `http://`/`https://`/`ftp://` URLs, and bare email addresses are auto-linked without angle brackets:

```markdown
Visit www.example.com or https://example.com or email user@example.com
```

**Disallowed raw HTML** — the tags `<title>`, `<textarea>`, `<style>`, `<xmp>`, `<iframe>`, `<noembed>`, `<noframes>`, `<script>`, and `<plaintext>` have their opening `<` escaped to `&lt;`.

Run the GFM suite with `zig build gfm`.

### Extensions

- **Frontmatter** — YAML (`---`), TOML (`+++`), JSON (`{`), and ZON (`.{`) extraction, all normalised to `std.json.Value`
- **Footnotes** — `[^label]` references and definitions
- **GFM Tables** — pipe-delimited tables with optional column alignment
- **GFM Task lists** — `- [x]` / `- [ ]` items rendered as disabled checkboxes
- **GFM Strikethrough** — `~~text~~` rendered as `<del>text</del>`
- **GFM Extended autolinks** — bare `www.`, `http(s)://`, `ftp://`, and email autolinks
- **GFM Disallowed raw HTML** — dangerous tags escaped at render time

## Building \& Testing

```bash
# Build CLI + shared library + docs
zig build

# Release build
zig build -Doptimize=ReleaseSafe

# Run unit tests
zig build test

# Run full CommonMark spec suite (summary)
zig build spec

# Run a single section with verbose failure output
zig build spec-emphasis

# Run GFM extension spec suite (summary)
zig build gfm

# Run a specific GFM extension section
zig build gfm-tables

# Generate docs
zig build docs
```

### Build Outputs

```
zig-out/
├── bin/zigmark           # CLI executable
├── lib/libzigmark.so     # C-callable shared library
├── include/zigmark.h     # C header
├── docs/                 # Generated documentation
└── wasm/                 # WebAssembly module (zig build wasm)
    ├── zigmark.wasm
    └── index.html        # Live preview demo
```

### WASM

Build the WebAssembly module (\~81 KiB):

```bash
zig build wasm
```

Serve the live preview demo locally:

```bash
# With Python
python3 -m http.server 8080 -d zig-out/wasm

# With Nix
nix run .#wasm-demo
```

Open `http://localhost:8080` — the demo renders Markdown in real-time using the
WASM module and includes a side-by-side benchmark against [marked.js](https://marked.js.org/).

See `examples/wasm/` for the WASM entry point and demo source.

### Nix

```bash
# Build
nix build

# Run
nix run . -- README.md

# Dev shell (includes zls, benchmark tool, auto-updates zon2json-lock)
nix develop

# WASM live preview demo
nix run .#wasm-demo

# Run CLI performance benchmark (compares zigmark vs cmark, updates README)
nix run .#bench
```

Requires **Zig 0.15.2** or later.

## Architecture

- **`Parser`** — Block-level + inline two-pass parser built on the [mecha](https://github.com/Hejsil/mecha) parser combinator library; accepts a `[]const u8` via `parseMarkdown` or any `*std.Io.Reader` via `parseFromReader`
- **`AST`** — Typed union-based Abstract Syntax Tree (`Document` → `Block` → `Inline`)
- **`HTMLRenderer`** — CommonMark-compliant HTML serialiser
- **`TypstRenderer`** — Typst markup renderer; `typst.renderDocument` adds an eisvogel-inspired preamble (title page, TOC, headers/footers, styled code blocks and blockquotes) driven by `DocumentOptions`
- **`ASTRenderer`** — Human-readable tree diagram with box-drawing characters
- **`AIRenderer`** — Token-efficient AST representation for LLM consumption
- **`MarkdownRenderer`** — AST→Markdown normaliser; converts headings to ATX, links to inline, code blocks to fenced
- **`Renderer`** — Type-erased vtable interface for pluggable output backends; exposes both `render → []u8` and `renderToWriter → void` paths
- **`Frontmatter`** — YAML/TOML/JSON/ZON metadata extraction, mutation (`set`, `delete`, `merge`), and re-serialisation; YAML via [zig-yaml](https://github.com/kubkon/zig-yaml), TOML via [tomlz](https://github.com/tsunaminoai/tomlz), JSON via `std.json`, ZON via a built-in recursive-descent parser
- **`Library`** — Queryable collection of documents; AND-combined frontmatter filters, block-type selectors (`@heading`, `@code_block`, …), confidence-ranked results, `addFromFile`/`addFromDir` bulk loading, and `sortBy` for in-place result ordering
- **C ABI** — Opaque-pointer API in `root.zig` exported as `libzigmark.so`

## Performance

<!-- bench-start -->

_Last updated: 2026-03-20 · input: `README.md` (26 KB) · run `nix run .#bench` to reproduce_

### Speed

| Command | Mean \[ms\] | Min \[ms\] | Max \[ms\] | Relative |
|:---|---:|---:|---:|---:|
| `lowdown` | 1.9 ± 0.7 | 1.2 | 5.5 | 1.00 |
| `discount` | 2.3 ± 0.8 | 1.5 | 7.7 | 1.20 ± 0.61 |
| **`zigmark (ReleaseFast)`** | 2.6 ± 0.7 | 1.9 | 7.2 | 1.36 ± 0.61 |
| **`zigmark (ReleaseSmall)`** | 3.2 ± 0.8 | 2.3 | 9.1 | 1.65 ± 0.71 |
| **`zigmark (ReleaseSafe)`** | 3.3 ± 1.4 | 2.1 | 18.0 | 1.71 ± 0.93 |
| `cmark-gfm` | 5.2 ± 1.8 | 3.2 | 17.1 | 2.74 ± 1.32 |
| `cmark` | 5.3 ± 2.7 | 3.0 | 29.4 | 2.78 ± 1.69 |
| `pandoc` | 155.3 ± 19.4 | 135.1 | 206.5 | 1.00 |

### Memory (peak RSS)

| Command | Peak RSS (KB) |
|:---|---:|
| **`zigmark (ReleaseSmall)`** | 1536 |
| **`zigmark (ReleaseFast)`** | 2000 |
| `discount` | 2040 |
| **`zigmark (ReleaseSafe)`** | 2084 |
| `lowdown` | 3024 |
| `cmark` | 4172 |
| `cmark-gfm` | 4172 |
| `pandoc` | 128988 |

<!-- bench-end -->

## Future Plans

- Additional renderers (plain text)
- AST modification API

## License

[PolyForm Noncommercial 1.0.0](LICENSE) © 2025 Star City Security Consulting, LLC (SC2)

Free to use for any **noncommercial** purpose — personal projects, research,
education, nonprofits, and government institutions are all welcome.

**Commercial use requires a separate licence.** If you or your organisation
intend to profit from zigmark (products, SaaS, consulting work billed to a
client, etc.) contact <**licensing@sc2.in>\*\*.  Commercial licensees also get
priority support and the option to sponsor features.

**Solo practitioners and independent consultants** using zigmark as a tool in
their own practice — not reselling it or embedding it in a product — are
welcome to use it without a commercial licence.

## Contributing

Contributions are welcome. By submitting a pull request you agree that your
contribution is licensed under the same AGPL-3.0-or-later terms as the rest of
this project.

### Security

**Do not open a public issue for security vulnerabilities.**

If you discover a security issue, please report it responsibly by emailing
<**security@sc2.in>\*\* with a description of the vulnerability, steps to
reproduce, and any relevant details. You will receive acknowledgement within 72
hours and we will work with you on a fix before any public disclosure.

### Guidelines

- **Tests must pass.** Run `zig build test` (unit), `zig build spec` (all
  652 CommonMark spec tests), and `zig build gfm` (all 24 GFM extension
  tests) before opening a PR.
- **One concern per PR.** Keep pull requests focused — a bug fix, a new
  feature, or a refactor, not all three at once.
- **No spec regressions.** The 652/652 CommonMark 0.31.2 and 24/24 GFM
  pass rates are the baseline. PRs that cause spec failures will not be merged.
- **Follow existing style.** The codebase uses `zig fmt`-standard formatting
  and descriptive naming. When in doubt, match what's already there.
- **Document public API changes.** If you add or change an exported function,
  update the README and/or `include/zigmark.h` accordingly.
- **Sign your commits.** Use `git commit -s` to add a `Signed-off-by` line
  ([DCO](https://developercertificate.org/)).
