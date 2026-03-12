# zigmark

A simple and efficient markdown parser and renderer library for Zig. Converts CommonMark-compatible markdown to an Abstract Syntax Tree (AST) and renders it to HTML.

## Features

### Parsing

- **Headings**: Support for all 6 heading levels (`#` to `######`)
- **Inline Elements**:
  - Bold text with `**text**` or `__text__`
  - Italic text with `_text_` or `*text*`
  - Code spans with `` `code` `` syntax
  - Links with `[text](url)` and reference-style `[text][ref]` syntax
  - Images with `![alt](url)` and reference-style syntax
  - Autolinks with `<url>` and `<email>` syntax
  - Backslash escapes of ASCII punctuation
  - Entity and numeric character references (`&amp;`, `&#123;`, `&#x7E;`)
  - Hard line breaks (trailing spaces and backslash)
  - Footnotes with `[^label]` references
- **Block Elements**:
  - Paragraphs
  - ATX headings (`#` to `######`) and setext headings
  - Lists (both ordered and unordered, loose and tight)
  - Blockquotes with `>`
  - Fenced code blocks (with info strings) and indented code blocks
  - Thematic breaks
  - Link reference definitions
  - Raw HTML blocks
- **Frontmatter Support**:
  - YAML frontmatter parsing
  - TOML frontmatter parsing
  - Access frontmatter as JSON
- **Advanced Query System**: jQuery-like selectors for AST navigation and traversal

### Rendering

- **HTML Output**: Complete HTML rendering of parsed markdown documents
- **Pluggable Renderer Architecture**: Extensible renderer interface for custom output formats

## Usage

### As a Library

Add `zigmark` as a dependency in your `build.zig.zon`:

```
.dependencies = .{
    .zigmark = .{
        .url = "https://github.com/sc2in/zigmark/archive/<commit>.tar.gz",
        .hash = "...",
    },
}
```

#### Basic Parsing and Rendering Example

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

#### Query System

Access specific elements in the parsed document:

```zig
var query = doc.get();

// Get all headings
var headings = try query.headings(allocator, null);
defer headings.deinit();

// Get all level 2 headings
var h2s = try query.headings(allocator, 2);
defer h2s.deinit();

// Get all links
var links = try query.links(allocator);
defer links.deinit();

// Count elements
let paragraph_count = query.count(AST.Paragraph);
```

#### Frontmatter Handling

```zig
var frontmatter = try zigmark.markdown.frontmatter.FrontMatter.initFromMarkdown(
    allocator, 
    markdown_content
);
defer frontmatter.deinit();

// Access frontmatter values
if (frontmatter.get("title")) |title| {
    std.debug.print("Title: {s}\n", .{title});
}
```

### As a Binary

Build and run the executable:

```bash
zig build
./zig-out/bin/zigmark
```

## Architecture

### Core Components

- **`Parser`**: Main parsing interface that converts markdown to AST
- **`AST`**: Abstract Syntax Tree representations of markdown documents
  - `Document`: Root node containing block elements
  - `Block`: Block-level elements (headings, paragraphs, lists, etc.)
  - `Inline`: Inline elements (bold, italic, links, etc.)
  - `Query`: Query interface for traversing and searching the AST
- **`Renderer`**: Pluggable rendering system
  - `HTMLRenderer`: Renders AST to HTML
  - Extensible for custom renderers
- **`FrontMatter`**: YAML/TOML metadata extraction from markdown documents
- **`Tokens`**: Lexical tokens used during parsing

## Building

### Requirements

- Zig compiler (latest nightly)
- Dependencies managed via `build.zig.zon`

### Build Commands

```bash
# Build the library and executable
zig build

# Run tests
zig build test

# Install artifacts
zig build install
```

## Dependencies

- `mecha`: Parser combinator library
- `yaml`: YAML parsing
- `tomlz`: TOML parsing
- `mvzr`: Utility library
- `datetime`: Date/time handling

## Testing

The project includes comprehensive tests for parsing and rendering:

```bash
zig build test
```

## Future Enhancements

Priority features and improvements planned for future releases:

1. **CommonMark Spec Compliance**: 547/655 (83%) spec tests passing — tracked in [TODO.md](TODO.md)
2. **Extended Syntax Support**:
   - Tables (GFM-style)
   - Strikethrough with `~~text~~`
   - Task lists
   - Definition lists
3. **HTML Attributes**: Support for custom attributes on HTML elements
4. **Additional Renderers**:
   - Markdown-to-Markdown normalization
   - LaTeX output renderer
   - Plain text renderer
5. **Performance Optimization**: Streaming parser for large documents
6. **Error Recovery**: Better error messages and recovery during parsing
7. **AST Modification API**: Programmatic manipulation of parsed documents
8. **Container Blocks**: Support for nested block structures and custom containers

## License

AGPL-3.0-or-later © 2025 Star City Security Consulting, LLC (SC2)
