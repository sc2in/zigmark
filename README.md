# zigmark

A CommonMark-compliant Markdown parser and HTML renderer for Zig. Passes **all 564 spec tests** (100%).

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

### Options

```
Usage: zigmark [OPTIONS] [FILE]

  -h, --help          Display this help and exit.
  -v, --version       Print version and exit.
  -f, --format <str>  Output format: "html" (default) or "ast".
  -o, --output <str>  Write output to FILE instead of stdout.
```

## Library Usage

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

### Custom Renderers

The renderer interface is pluggable — implement a `render(Allocator, AST.Document) ![]u8` function:

```zig
const MyRenderer = zigmark.Renderer.create(my_backend);
const output = try MyRenderer.render(allocator, doc);
```

## Features

### CommonMark Compliance — 564/564 ✅

Every section of the [CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/) spec passes:

| Section | Tests |
|---------|-------|
| ATX headings | 18 |
| Setext headings | 27 |
| Thematic breaks | 19 |
| Paragraphs | 8 |
| Blank lines | 1 |
| Indented code | 12 |
| Fenced code | 29 |
| Lists | 67 |
| Backslash escapes | 13 |
| Entities | 17 |
| Code spans | 22 |
| Emphasis | 132 |
| Links | 117 |
| Images | 22 |
| Autolinks | 19 |
| Raw HTML | 21 |
| Hard line breaks | 15 |
| Soft line breaks | 2 |
| Textual content | 3 |

### Extensions

- **Frontmatter** — YAML (`---`) and TOML (`+++`) extraction, parsed as JSON
- **Footnotes** — `[^label]` references and definitions

## Building & Testing

```bash
# Build library + CLI
zig build

# Run unit tests
zig build test

# Run full CommonMark spec suite (summary)
zig build spec

# Run a single section with verbose failure output
zig build spec-emphasis

# Generate docs
zig build docs
```

Requires **Zig 0.15.2** or later.

## Architecture

- **`Parser`** — Block-level + inline two-pass parser built on the [mecha](https://github.com/Hejsil/mecha) parser combinator library
- **`AST`** — Typed union-based Abstract Syntax Tree (`Document` → `Block` → `Inline`)
- **`HTMLRenderer`** — CommonMark-compliant HTML serialiser
- **`Renderer`** — Type-erased vtable interface for pluggable output backends
- **`FrontMatter`** — YAML/TOML metadata extraction via [zig-yaml](https://github.com/kubkon/zig-yaml) and [tomlz](https://github.com/tsunaminoai/tomlz)

## Future Plans

- GFM extensions (tables, strikethrough, task lists)
- Additional renderers (LaTeX, plain text, Markdown normaliser)
- Streaming parser for large documents
- AST modification API

## License

AGPL-3.0-or-later © 2025 Star City Security Consulting, LLC (SC2)
