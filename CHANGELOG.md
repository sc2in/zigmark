# Changelog

All notable changes to zigmark are documented here.

Versions track the library API, not Zig itself.  The major version will
remain 0.x until Zig reaches 1.0, at which point zigmark will follow the
same stability guarantee.

## [Unreleased]

## [0.7.2] — 2026-07-03

### Fixed

- **Typst mermaid embeds now actually compile.** The Typst renderer emitted
  `#image.decode(bytes.fromBase64("…"))`, but `bytes.fromBase64` does not
  exist in Typst (and `image.decode` is deprecated) — every document with a
  rendered mermaid block failed `typst compile`. Diagrams are now embedded as
  `image(bytes("<svg…>"), format: "svg")` with the SVG source in a string
  literal (verified against typst 0.14.2). The existing tests only asserted
  the emitted string, which is how this slipped through.
- Mermaid diagrams are rendered at their natural size and only scaled down
  when wider than the line width (via a `layout`/`measure` wrapper), instead
  of being blown up to full text width.

### Added

- `renderTypstWithMermaid` / `TypstRenderer`'s `renderToWriterWithMermaid` —
  body-only Typst rendering with the mermaid hook, for callers that supply
  their own preamble (previously the hook was only reachable through the
  full-document `renderTypstDocWithMermaid`).

## [0.7.0] — 2026-06-04

### Breaking

- **Minimum Zig version is now 0.16.0.** Zig 0.15.x is no longer supported.

### Added

- **GFM extension support** — Tables, task lists, strikethrough, extended autolinks, disallowed raw HTML. All 24/24 GFM extension spec tests pass.
- **Mermaid diagram rendering** — Fenced `` ```mermaid `` blocks rendered to SVG via `pozeiden` (CLI + WASM). No-op fallback when used as a library dependency.
- **Fuzz testing** — `zig build fuzz` for smoke tests; `zig build fuzz --fuzz` activates coverage-guided fuzzing with the Zig web UI.
- **WASM demo** — Live Markdown preview: `nix run .#wasm-demo`.
- **Benchmark app** — `nix run .#bench` runs `hyperfine` against cmark, cmark-gfm, pandoc, discount, and lowdown and writes results back to `README.md`.

### Fixed

- CI matrix now runs correctly on `x86_64-linux` and `aarch64-linux` via `om ci run --systems` with explicit `OM_SYSTEM` injection.
- FlakeHub publish step re-enabled in `release.yml` (was commented out since v0.6.0). Fixes #43.
- WASM: all 27 WASI imports (`random_get`, `clock_res_get`, `poll_oneoff`, all `fd_*`/`path_*`) stubbed in `index.html`; demo was previously broken with a `LinkError`.
- `nix run .#wasm-demo` now includes `pkgs.zig` in `runtimeInputs` so it works outside the dev shell.

### Known issues (open bugs)

- **#57** — Terminal renderer inline images disabled (`std.posix.getenv` / `std.fs` removed in Zig 0.16; text rendering unaffected)
- **#58** — Spec runner per-test timing always shows `0.00 ms` (`std.time.nanoTimestamp` removed in Zig 0.16; pass/fail counts are correct)

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
