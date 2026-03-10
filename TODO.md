# CommonMark Compliance TODO

This document tracks the work needed to achieve full CommonMark 0.30 specification compliance.

**Current score: 256 / 655 (39%) — 51 unit tests passing, 0 memory leaks**

Per-section breakdown (via `zig build spec`):

| Section | Pass | Fail | Total |
|---------|------|------|-------|
| ATX headings | 14 | 4 | 18 |
| Setext headings | 14 | 13 | 27 |
| Thematic breaks | 13 | 6 | 19 |
| Paragraphs | 5 | 3 | 8 |
| Blank lines | 1 | 0 | 1 |
| Indented code | 1 | 11 | 12 |
| Fenced code | 5 | 24 | 29 |
| Lists | 17 | 50 | 67 |
| Backslash escapes | 3 | 10 | 13 |
| Entities | 2 | 15 | 17 |
| Code spans | 10 | 12 | 22 |
| **Emphasis** | **44** | **88** | **132** |
| **Links** | **62** | **55** | **117** |
| Images | 7 | 15 | 22 |
| Autolinks | 12 | 7 | 19 |
| Raw HTML | 11 | 10 | 21 |
| Hard line breaks | 5 | 10 | 15 |
| Soft line breaks | 2 | 0 | 2 |
| Textual content | 3 | 0 | 3 |

## Block Elements

### Headings

- [x] **Setext headings** - Alternative heading syntax using underlines (`===` and `---`)
  - Required for full CommonMark compliance
  - Both `=` (level 1) and `-` (level 2) variants

### Code Blocks

- [x] **Indented code blocks** - 4-space indentation for code
  - Currently only fenced code blocks are supported
  - Must handle blank lines and interruption rules

### Link References

- [x] **Link reference definitions** - `[label]: url "title"` syntax
  - Two-pass architecture: first pass collects ref defs, second pass builds AST
  - Case-insensitive label matching with whitespace normalisation
  - First definition wins (per CommonMark spec)
  - Supports all three title delimiter styles (`"`, `'`, `(…)`)
- [x] **Reference links (full style)** - `[text][label]`
- [x] **Reference links (collapsed)** - `[text][]`
- [x] **Reference links (shortcut)** - `[text]` with definition elsewhere

### Paragraph/List Behavior

- [ ] **Lazy continuation lines** - Especially in blockquotes and lists
  - Blockquote laziness rules
  - List item laziness
  - Paragraph continuation

## Inline Elements

### Escape Sequences

- [x] **Backslash escapes** - `\` escaping of special characters
  - Escape punctuation and special markdown characters
  - Handle in all contexts (emphasis, links, code, etc.)

### Character References

- [ ] **Entity and numeric character references** - `&amp;`, `&#123;`, etc.
  - HTML entity resolution
  - Numeric character references (decimal and hex)

### Emphasis and Strong Emphasis

- [ ] **Proper emphasis/strong emphasis rules** - Complex delimiter matching
  - 17 rules for emphasis from CommonMark spec
  - Left/right-flanking delimiter runs
  - Can open/close emphasis based on surrounding characters
  - Proper precedence with other inline elements

### Links

- [x] **Reference links (full style)** - `[text][label]`
- [x] **Reference links (collapsed)** - `[text][]`
- [x] **Reference links (shortcut)** - `[text]` with definition elsewhere
- [x] **Proper link destination parsing** - Nested parentheses, angle-bracket destinations, backslash escapes, space rejection in bare URLs
- [x] **Link titles** - Support `"`, `'`, and `(…)` quote styles
- [ ] **Nested links** - Links inside link text (CommonMark forbids nesting)

### Autolinks

- [x] **Proper autolinks** - `<http://example.com>` and `<user@example.com>`
  - URI autolinks with scheme validation
  - Email autolinks with proper regex matching
  - Backslash escape handling (disabled in autolinks)

### Images

- [ ] **Complete image syntax** - Full support with all reference styles
  - Inline images: `![alt](url "title")`
  - Reference images: `![alt][ref]`
  - Collapsed: `![alt][]`
  - Shortcut: `![alt]`
  - Proper alt text (plain text content)

## Specification Compliance

### Indentation and Whitespace

- [ ] **Indentation rules** - Up to 3 spaces allowed before blocks, 4+ = code block
  - Proper handling in all contexts
  - Interaction with list items and blockquotes
- [ ] **Tab handling** - Proper tab expansion (tab stop = 4 characters)
  - Character classification respecting tabs
  - Line beginning calculations

### List Processing

- [x] **Loose vs tight lists** - Proper `<p>` tag insertion logic
  - Blank lines between items trigger loose list
  - Blank lines within items trigger loose list
  - Affects HTML rendering
- [ ] **Indentation in list items** - Correct spacing rules for nested content
  - 4-space rule for content within list items
  - Proper nesting of code blocks, blockquotes, etc.
- [ ] **List interruption** - Only ordered lists starting with `1` can interrupt paragraphs
  - Prevent false list detection in wrapped text

### Blockquotes

- [ ] **Lazy continuation lines** - Omitted `>` on paragraph continuation
- [ ] **Nested blockquotes** - Proper `>` marker stacking
- [ ] **Blockquote interruption** - Can interrupt paragraphs without blank line

### HTML Handling

- [ ] **Raw HTML blocks** - 7 types of HTML block recognition
  - Type 1: `<script>`, `<pre>`, `<style>`, `<textarea>` with end tags
  - Type 2: HTML comments `<!-- -->`
  - Type 3: Processing instructions `<?...?>`
  - Type 4: Declarations `<!...>`
  - Type 5: CDATA `<![CDATA[...]]>`
  - Type 6: Block-level HTML tags
  - Type 7: Open/close tags (not in type 6)
- [ ] **Inline HTML** - Proper `<tag>` parsing as inline
  - Tag validation
  - Attribute parsing

## Other Missing Features

### Line Handling

- [x] **Proper line ending normalization** - CRLF, LF, CR handling
  - Normalize to single character
  - Handle in all contexts

### Precedence Rules

- [ ] **Correct precedence** - Block structure > inline structure
  - Code spans > emphasis
  - Links > emphasis  
  - HTML tags > links and emphasis

### Advanced Features

- [x] **Thematic break interruption** - Can interrupt paragraphs
- [ ] **Paragraph interruption rules** - Various block types can interrupt
- [ ] **Container nesting** - Proper nesting of blockquotes, lists, etc.
- [ ] **Reference link definition placement** - Can occur anywhere, affects whole document
  - *(Partially done — two-pass architecture implemented, but ref defs inside blockquotes/lists not yet fully handled)*

## Currently Implemented ✅

- ✅ Basic ATX headings (`#` to `######`) — 14/18 passing
- ✅ Setext headings (`===` and `---` underlines) — 14/27 passing
- ✅ Paragraphs (basic) — 5/8 passing
- ✅ Basic emphasis/strong (`*` and `_` variants) — 44/132 passing
- ✅ Inline links `[text](url)` with nested parens, angle-bracket destinations, backslash escapes
- ✅ Link reference definitions `[label]: url "title"` — two-pass architecture
- ✅ Reference links: full `[text][label]`, collapsed `[text][]`, shortcut `[text]`
- ✅ Link titles (all three quote styles: `"`, `'`, `(…)`)
- ✅ URL percent-encoding in rendered HTML (`writeUrlEncoded`)
- ✅ Basic images `![alt](url)` — 7/22 passing
- ✅ Autolinks (`<uri>` and `<email>`) — 12/19 passing
- ✅ Unordered and ordered lists (basic) — 17/67 passing
- ✅ Loose vs tight list detection
- ✅ Blockquotes (basic, with lazy continuation)
- ✅ Code spans (basic) — 10/22 passing
- ✅ Fenced code blocks (with info strings) — 5/29 passing
- ✅ Indented code blocks (4-space / tab)
- ✅ Thematic breaks — 13/19 passing
- ✅ Backslash escapes of ASCII punctuation — 3/13 passing
- ✅ Soft breaks and hard breaks (2+ trailing spaces) — 7/17 passing
- ✅ Line ending normalization (CRLF, CR, LF)
- ✅ Footnotes (extension, not in CommonMark)
- ✅ Frontmatter support (YAML/TOML — extension, not in CommonMark)

## Testing

- [x] Run CommonMark spec test suite (<https://github.com/commonmark/commonmark-spec/blob/master/test/spec_tests.py>)
- [x] Implement test runner for spec examples
- [x] Track compliance percentage
- [x] Per-section spec build steps (`zig build spec`, `zig build spec-emphasis`, etc.)
- [x] Verbose failure output per section (`zig build spec-links` shows each failing example)
- [x] Comprehensive docstrings on all public API members (auto-doc generation via `zig build docs`)
- [ ] Document any intentional deviations from spec

## Biggest Opportunities (by failing test count)

1. **Emphasis** — 88 failures (needs left/right flanking delimiter run algorithm)
2. **Links** — 55 failures (edge cases: nested links, entity handling in URLs, etc.)
3. **Lists** — 50 failures (indentation, interruption, nested content)
4. **Fenced code** — 24 failures (indentation stripping, closing fence rules)
5. **Entities** — 15 failures (HTML entity & numeric character reference resolution)
6. **Images** — 15 failures (reference images, nested alt text)
7. **Setext headings** — 13 failures (interaction with other block types)
8. **Code spans** — 12 failures (multi-backtick, stripping, line ending handling)
