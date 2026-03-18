# zigmark

A CommonMark-compliant Markdown parser and HTML renderer for Zig. Passes **all 652 CommonMark spec tests** and **all 24 GFM extension tests** (100%).

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

### Options

```
Usage: zigmark [OPTIONS] [FILE]

  -h, --help          Display this help and exit.
  -v, --version       Print version and exit.
  -f, --format <str>  Output format: "html" (default), "ast", "ai", "terminal",
                      or "frontmatter".
  -o, --output <str>  Write output to FILE instead of stdout.
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
|--------|---------------|---------|
| YAML   | `---`          | `--- \ntitle: Hello\n---` |
| TOML   | `+++`          | `+++\ntitle = "Hello"\n+++` |
| JSON   | `{`            | `{"title": "Hello"}` |
| ZON    | `.{`           | `.{ .title = "Hello" }` |

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

### Custom Renderers

The renderer interface is pluggable — implement a `render(Allocator, AST.Document) ![]u8` function:

```zig
const MyRenderer = zigmark.Renderer.create(my_backend);
const output = try MyRenderer.render(allocator, doc);
```

## C Shared Library

The build produces `libzigmark.so` and `include/zigmark.h` — a self-contained shared library with no libc dependency.

### C API

```c
#include "zigmark.h"

ZigmarkDocument *zigmark_parse(const char *input, size_t len);
void             zigmark_free_document(ZigmarkDocument *doc);

char            *zigmark_render_html(ZigmarkDocument *doc);
char            *zigmark_render_ast(ZigmarkDocument *doc);
char            *zigmark_render_ai(ZigmarkDocument *doc);
void             zigmark_free_string(char *str);

const char      *zigmark_version(void);
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
|---------|-------|
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

| GFM Extension          | Tests   |
|------------------------|---------|
| Tables                 | 8/8 ✅  |
| Task list items        | 2/2 ✅  |
| Strikethrough          | 2/2 ✅  |
| Autolinks (extended)   | 11/11 ✅ |
| Disallowed raw HTML    | 1/1 ✅  |

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

## Building & Testing

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

Build the WebAssembly module (~81 KiB):

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
```

Requires **Zig 0.15.2** or later.

## Architecture

- **`Parser`** — Block-level + inline two-pass parser built on the [mecha](https://github.com/Hejsil/mecha) parser combinator library
- **`AST`** — Typed union-based Abstract Syntax Tree (`Document` → `Block` → `Inline`)
- **`HTMLRenderer`** — CommonMark-compliant HTML serialiser
- **`ASTRenderer`** — Human-readable tree diagram with box-drawing characters
- **`AIRenderer`** — Token-efficient AST representation for LLM consumption
- **`Renderer`** — Type-erased vtable interface for pluggable output backends
- **`Frontmatter`** — YAML/TOML/JSON/ZON metadata extraction; YAML via [zig-yaml](https://github.com/kubkon/zig-yaml), TOML via [tomlz](https://github.com/tsunaminoai/tomlz), JSON via `std.json`, ZON via a built-in recursive-descent parser
- **C ABI** — Opaque-pointer API in `root.zig` exported as `libzigmark.so`

## Future Plans

- Additional renderers (LaTeX, plain text, Markdown normaliser)
- Streaming parser for large documents
- AST modification API

## License

AGPL-3.0-or-later © 2025 Star City Security Consulting, LLC (SC2)

## Contributing

Contributions are welcome. By submitting a pull request you agree that your
contribution is licensed under the same AGPL-3.0-or-later terms as the rest of
this project.

### Security

**Do not open a public issue for security vulnerabilities.**

If you discover a security issue, please report it responsibly by emailing
**security@sc2.in** with a description of the vulnerability, steps to
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
