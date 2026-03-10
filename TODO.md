# CommonMark Compliance TODO

This document tracks the work needed to achieve full CommonMark 0.30 specification compliance.

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

- [ ] **Link reference definitions** - `[label]: url "title"` syntax
  - Parse reference definitions from document
  - Support inline, reference, collapsed, and shortcut link styles
  - Handle case-insensitive matching with Unicode case folding

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

- [ ] **Reference links (full style)** - `[text][label]`
- [ ] **Reference links (collapsed)** - `[text][]`
- [ ] **Reference links (shortcut)** - `[text]` with definition elsewhere
- [ ] **Proper link destination parsing** - Space handling, escaping, etc.
- [x] **Link titles** - Support `"` and `'` quote styles (parenthesis style not yet implemented)

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

## Currently Implemented ✅

- ✅ Basic ATX headings (`#` to `######`)
- ✅ Setext headings (`===` and `---` underlines)
- ✅ Paragraphs (basic)
- ✅ Basic emphasis/strong (`*` and `_` variants)
- ✅ Basic inline links `[text](url)`
- ✅ Link titles (`"` and `'` quote styles)
- ✅ Basic images `![alt](url)`
- ✅ Autolinks (`<uri>` and `<email>`)
- ✅ Unordered and ordered lists (basic)
- ✅ Loose vs tight list detection
- ✅ Blockquotes (basic, with lazy continuation)
- ✅ Code spans (basic)
- ✅ Fenced code blocks (with info strings)
- ✅ Indented code blocks (4-space / tab)
- ✅ Thematic breaks
- ✅ Backslash escapes of ASCII punctuation
- ✅ Soft breaks and hard breaks (2+ trailing spaces)
- ✅ Line ending normalization (CRLF, CR, LF)
- ✅ Footnotes (extension, not in CommonMark)
- ✅ Frontmatter support (YAML/TOML - extension, not in CommonMark)

## Testing

- [x] Run CommonMark spec test suite (<https://github.com/commonmark/commonmark-spec/blob/master/test/spec_tests.py>)
- [x] Implement test runner for spec examples
- [x] Track compliance percentage
- [ ] Document any intentional deviations from spec
