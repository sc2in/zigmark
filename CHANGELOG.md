# Changelog

All notable changes to zigmark are documented here.

Versions track the library API, not Zig itself.  The major version will
remain 0.x until Zig reaches 1.0, at which point zigmark will follow the
same stability guarantee.

## [0.5.x] — current

### Added

- Code of Conduct and Contributing guidelines.
- WASI support for WebAssembly and benchmark results.
- Fuzz testing harness and coverage-guided fuzzing support.
- Mutation API for AST: block-level append, insert, remove, replace.
- CLI options for body mutation: `--set-block`, `--section-start`, `--section-end`.

### Changed

- Enhanced CI workflow for multi-architecture support and improved fuzzing instructions.
- Refactored build process: `mkZigmark` helper in `flake.nix`, pre-built binaries for benchmarks.
- Updated package version to 0.5.0.
- Formatting and release hygiene.

### Fixed

- CI workflow restricted to main branch only.

### Merged

- Develop/fuzzing branch (fuzzing harness, coverage, and docs).
- AST modification API and CLI integration.

## [0.4.x]

### Added (0.4.x)

- **Streaming IO** — `Parser.parseFromReader(*std.Io.Reader)` reads from any
  reader (file, stdin, pipe) without a `readToEndAlloc`; the returned
  `AST.Document` is fully self-contained and does not borrow from the input
  buffer.  All six renderers gain `renderToWriter(Allocator, *std.Io.Writer,
  AST.Document)` for zero-allocation output to files, sockets, or any writer.
  `Renderer.create` now requires `renderToWriter` alongside `render`.
  `typst.renderDocumentToWriter` mirrors `typst.renderDocument`.
- **Library** — queryable collection of parsed Markdown documents with
  frontmatter; AND-combined filters, block-type selectors (`@heading`,
  `@fenced_code_block`, …), confidence-ranked results, `addFromFile`,
  `addFromDir`, `sortBy`, and per-entry `content_hash` for change detection
- **TypstRenderer** — Typst markup output with eisvogel-inspired full-document
  mode (`typst.renderDocument`); frontmatter fields auto-mapped to title page,
  TOC, headers/footers, and typographic options
- **Frontmatter** — ZON format support (anonymous structs, array tuples, enum
  literals); `set`, `delete`, `merge`, and `serialize` mutations; C ABI
  (`zigmark_frontmatter_*`)
- **GFM extensions** — Tables, task lists, strikethrough, extended autolinks,
  disallowed raw HTML (24/24 tests)
- **Footnotes** — `[^label]` references and definitions
- CommonMark 652/652 spec compliance

### Fixed (0.4.x)

- `FencedCodeBlock.language` and `FootnoteDefinition.label` were borrowed
- `FencedCodeBlock.language` and `FootnoteDefinition.label` were borrowed
  slices that dangled when blockquote/list inner content buffers were freed
  during parsing.  Both are now owned allocations freed by their `deinit`.

### Infrastructure (0.4.x)

- Nix flake with reproducible builds and `nix run .#bench` performance tooling
- Nix flake with reproducible builds and `nix run .#bench` performance tooling
- `zig build spec` / `zig build gfm` spec suites with per-section targets
- C shared library (`libzigmark.so`) and header (`include/zigmark.h`)
- WASM module with live preview demo
