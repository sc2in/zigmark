# CommonMark Compliance

**Current score: 655 / 655 (100%) — all spec tests passing, 0 memory leaks** ✅ 🎉

Per-section breakdown (via `zig build spec`):

| Section | Pass | Fail | Total |
|---------|------|------|-------|
| Tabs | 11 | 0 | 11 | ✅
| Backslash escapes | 13 | 0 | 13 | ✅
| Entity and numeric character references | 17 | 0 | 17 | ✅
| Precedence | 1 | 0 | 1 | ✅
| Thematic breaks | 19 | 0 | 19 | ✅
| ATX headings | 18 | 0 | 18 | ✅
| Setext headings | 27 | 0 | 27 | ✅
| Indented code blocks | 12 | 0 | 12 | ✅
| Fenced code blocks | 29 | 0 | 29 | ✅
| HTML blocks | 46 | 0 | 46 | ✅
| Link reference definitions | 27 | 0 | 27 | ✅
| Paragraphs | 8 | 0 | 8 | ✅
| Blank lines | 1 | 0 | 1 | ✅
| Block quotes | 25 | 0 | 25 | ✅
| List items | 48 | 0 | 48 | ✅
| Lists | 27 | 0 | 27 | ✅
| Code spans | 22 | 0 | 22 | ✅
| Emphasis and strong emphasis | 132 | 0 | 132 | ✅
| Links | 90 | 0 | 90 | ✅
| Images | 22 | 0 | 22 | ✅
| Autolinks | 19 | 0 | 19 | ✅
| Raw HTML | 21 | 0 | 21 | ✅
| Hard line breaks | 15 | 0 | 15 | ✅
| Soft line breaks | 2 | 0 | 2 | ✅
| Textual content | 3 | 0 | 3 | ✅

## Implemented Features

### Block Elements

- [x] **ATX headings** — `#` to `######`, closing sequences, 0–3 space indent rule
- [x] **Setext headings** — `===` and `---` underlines, interaction with blockquotes and lazy continuation
- [x] **Thematic breaks** — `***`, `---`, `___` with spaces, 0–3 space indent rule, priority over list items
- [x] **Paragraphs** — Proper continuation and interruption rules
- [x] **Blank lines** — Correct handling in all block contexts
- [x] **Indented code blocks** — 4-space / tab indentation, blank line handling, interruption rules
- [x] **Fenced code blocks** — Backtick and tilde fences, info strings with entity decoding, indent stripping, leading blank line preservation
- [x] **Blockquotes** — `>` marker stripping with indentation preservation, lazy continuation lines, nested blockquotes, setext heading interaction
- [x] **Lists** — Full CommonMark list support (see below)
- [x] **HTML blocks** — All 7 types (script/pre/style/textarea, comments incl. `<!-->`, processing instructions, declarations, CDATA, block-level tags, open/close type 7 tags)
- [x] **Link reference definitions** — Two-pass architecture, case-insensitive labels, first-definition-wins, all title delimiter styles

### List Processing

- [x] **Loose vs tight lists** — Proper `<p>` tag insertion with `saw_blank_before_sublist` tracking to distinguish blank lines between top-level blocks vs inside nested sub-lists
- [x] **Multi-line list items** — Content column–based continuation with recursive block parsing
- [x] **List interruption** — Only ordered lists starting with `1` can interrupt paragraphs; empty items cannot interrupt
- [x] **Indentation in list items** — Content column computation for bullet and ordered markers, 0–3 space indent rule for list markers
- [x] **Lazy continuation lines** — Paragraph continuation without full indentation, with 4-space indent prefix for lines that look like list markers to prevent re-interpretation by inner parser
- [x] **Thematic break priority** — Thematic breaks take precedence over list items (e.g. `* * *`)

### Inline Elements

- [x] **Backslash escapes** — `\` escaping of ASCII punctuation in all contexts
- [x] **Entity and numeric character references** — 120+ named entities, decimal/hex numeric refs, multi-codepoint entities, decoding in text/URLs/titles/info strings
- [x] **Emphasis and strong emphasis** — All 17 CommonMark rules, left/right-flanking delimiter runs, multi-byte Unicode whitespace/punctuation detection
- [x] **Links** — Inline, full reference, collapsed, shortcut styles; nested parentheses; angle-bracket destinations; all title quote styles; nested link prevention
- [x] **Images** — All reference styles, proper alt text flattening
- [x] **Autolinks** — URI scheme validation (2–32 chars), email autolinks, backslash rejection, backtick percent-encoding
- [x] **Code spans** — Backtick strings, space collapsing, proper precedence
- [x] **Raw inline HTML** — Tag validation, attribute parsing (quoted/unquoted/boolean), multi-line tags
- [x] **Hard line breaks** — Trailing spaces (`<br />\n`) and backslash breaks
- [x] **Soft line breaks** — Newline normalization

### Other

- [x] **Proper line ending normalization** — CRLF, LF, CR handling
- [x] **Correct precedence** — Block structure > inline structure, code spans > emphasis, links > emphasis
- [x] **Unicode case folding** — Greek, Cyrillic, Latin Extended, ẞ→ss for link labels
- [x] **Frontmatter support** — YAML/TOML (extension, not in CommonMark)
- [x] **Footnotes** — Extension, not in CommonMark

## Testing

- [x] Run CommonMark spec test suite
- [x] Implement test runner for spec examples
- [x] Track compliance percentage
- [x] Per-section spec build steps (`zig build spec`, `zig build spec-emphasis`, etc.)
- [x] Verbose failure output per section (`zig build spec-links` shows each failing example)
- [x] Comprehensive docstrings on all public API members (auto-doc generation via `zig build docs`)
- [ ] Document any intentional deviations from spec
