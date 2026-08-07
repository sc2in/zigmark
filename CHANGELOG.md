# Changelog

All notable changes to zigmark are documented here.

Versions track the library API, not Zig itself.  The major version will
remain 0.x until Zig reaches 1.0, at which point zigmark will follow the
same stability guarantee.

## [Unreleased]

### Changed

- Bumped the lazy `pozeiden` dependency v0.2.0 → v0.4.0, picking up its two
  0.3.0 security fixes (GHSA-p2c5-qmq5-3r4f SVG/XSS injection,
  GHSA-rg4m-w3p2-gf3p out-of-bounds writes) plus the 0.4.0 hardening and
  layout work. **Behaviour change:** mermaid SVG emitted by the CLI/WASM
  paths changes bytes — the default font stack now ends in
  `Liberation Sans, DejaVu Sans, sans-serif`, and `accTitle:`/`accDescr:`
  directives become SVG `<title>`/`<desc>` accessibility metadata.

## [0.11.0] — 2026-07-23

### Added

- **Programmatic footnote synthesis** (`zigmark.footnotes`). A new module lets a
  caller supply footnote definitions on demand through a `Resolver` callback:
  `resolve(alloc, &doc, resolver, .{})` finds every `[^label]` reference that
  has no matching definition (walking paragraphs, headings, blockquotes, list
  items, table cells, and footnote-definition bodies, plus emphasis/strong/
  strikethrough/link inlines), parses the resolver's Markdown, and appends real
  `footnote_definition` blocks in first-reference order. Because synthesis
  happens at the AST level, every renderer benefits with **zero renderer
  changes** — in particular the Typst back-end expands the now-defined
  references to native `#footnote[…]`. `resolve` is single-pass;
  `dangling(alloc, &doc)` returns the deduplicated labels that are still
  undefined (in first-reference order) so consumers can hard-fail a build. The
  resolver-returned slice is owned and freed by zigmark (the `MermaidRendererFn`
  ownership contract). See #82.
- **`Library.footnoteResolver()`** — a `footnotes.Resolver` that sources
  definition bodies from the footnote definitions found across a library's
  documents (first match wins). The intended pattern is to build a glossary
  document of `[^ID]: …` lines from external data, `add()` it to the library,
  and pass `lib.footnoteResolver()` to `footnotes.resolve`. Nothing
  domain-specific lands in zigmark.
- `renderers/markdown.zig`'s `renderBlock` is now `pub`, so callers can
  serialise a node's child blocks back to Markdown without wrapping a whole
  document (used by `footnoteResolver`).

### Changed

- **Footnote-definition labels now accept a much wider charset.** A label may
  contain any byte except ASCII whitespace (space, tab, CR, LF) and the square
  brackets `[` / `]`, rather than only `[a-zA-Z0-9]`. This is the intersection
  of pulldown-cmark (Zola) and cmark-gfm (GitHub), so control-ID-shaped labels
  such as `IAC-21.5` or `SCF:GOV-01` now parse to the same definition in
  zigmark, on GitHub, and in Zola. Both parser call sites (footnote definition
  parsing and paragraph interruption) route through the one combinator, and the
  reference parser is unchanged (it already accepts a permissive superset).
  - **Behaviour change:** a whitespace-free line shaped like `[^word]: …` — with
    a label the old charset rejected (e.g. `[^SCF:GOV-01]: text`) — now parses
    as a footnote **definition** where previous releases treated it as an
    ordinary paragraph containing a footnote reference. Lines whose label
    contains a space (e.g. `[^see note]: x`) still stay paragraphs. The 0.8.0
    HTML-escaping guarantee for footnote labels extends to (and is tested on)
    the definition and synthesis paths. CommonMark/GFM spec conformance is
    unchanged (652/652 + 24/24).

### Fixed

- **Front-matter YAML plain scalars containing an interior indicator character
  now parse** (`&`, `*`, `!`, and a block-sequence `-`). Previously an unquoted value such as
  `name: cloud & edge` failed with `ParseFailure` and the whole document was
  rejected — a `&` was mistaken for a mid-scalar anchor indicator even though
  YAML only treats it as one at node start. This regularly bit titles and
  descriptions (issue #81, reported downstream from PolicyPress). Fixed in the
  vendored `zig-yaml` parser (bumped 0.3.1 → 0.3.2): interior
  anchor/alias/tag/seq-item tokens are folded into the plain scalar as content
  instead of terminating it — the same class as the 0.3.1
  comment-in-plain-scalar fix. Quoting the value already worked and is
  unchanged; CommonMark/GFM spec conformance is unchanged (652/652 + 24/24).

### Added

- **Front-matter round-trip fuzz oracle** (`fuzz_frontmatter_yaml_roundtrip` in
  `src/fuzz.zig`). Beyond the existing no-crash targets, it asserts that a value
  set into YAML front matter survives `serialize` → re-parse. Because the
  emitter leaves interior indicator characters unquoted, this catches
  serializer↔parser disagreements — the class of spurious `ParseFailure` that
  the no-crash targets swallow — and would have caught both issue #81 and the
  earlier `#`-comment case automatically. `zig build fuzz` (smoke) runs it in
  CI; `zig build fuzz --fuzz` runs it coverage-guided.

## [0.10.0] — 2026-07-18

### Changed

- **Unquoted YAML front-matter scalars are now typed like TOML.** `true`/`false`
  become `.bool` and `null` becomes `.null` (in addition to the existing
  int/float coercion), so `Frontmatter.get` returns the same `std.json.Value`
  tag regardless of whether the source was YAML or TOML. Previously an unquoted
  YAML boolean came back as `.string` (`"true"`) while the identical TOML value
  came back as `.bool`, so a consumer could not switch on the value type
  portably. Quoted scalars still stay `.string`, so `flag: "true"` is unchanged.
  The typing now flows through the same `inferValue` helper the CLI
  `--set key=value` path uses (#79).

### Fixed

- **Typst math equations now carry `alt` text.** The renderer emits
  `#mi("…", alt: "…")` / `#mitex("…", alt: "…")` with the TeX source as the alt
  argument (mitex forwards `..args` straight to `math.equation`), so a document
  containing math compiles under Typst's PDF/UA-1 tagged-PDF mode
  (`typst compile --pdf-standard ua-1`), which hard-fails on any equation
  without alt text. Consumers no longer need a document-wide
  `#set math.equation(alt: …)` stopgap, and each equation gets a meaningful
  per-equation description instead of one generic string. The alt argument is
  string-literal-escaped with the same guard as the content, so it cannot break
  out of the literal (#78).

## [0.9.0] — 2026-07-16

### Fixed

- **A trailing `# comment` after a plain scalar no longer breaks front-matter
  parsing.** YAML like `- date: 2025-01-01  # when` inside a block sequence
  (e.g. a policy revision entry) previously failed the whole document with
  `ParseFailure`. Fixed upstream in the sc2in/zig-yaml fork (0.3.1, "comment
  terminates a plain scalar"); this release bumps the pin and adds
  front-matter regression tests.

### Added

- **Opt-in TeX math** (`Parser{ .math = true }`; off by default). `$…$` parses
  to an inline `AST.Math` node and `$$…$$` to a display one, with
  Pandoc/KaTeX-auto-render delimiter rules: the opener `$` must not be
  followed by whitespace, the closer must not be preceded by whitespace nor
  followed by an ASCII digit (so `$5 and $6` stays text), `\$` never opens
  math, `$` inside code spans is untouched, and an unmatched `$` falls back to
  literal text. With the flag off (the default), output is byte-identical to
  0.8.0 and CommonMark/GFM conformance is unchanged (652/652 + 24/24).
- **Math rendering across all renderers.** Typst emits `#mi("…")` /
  `#mitex("…")` with the TeX source in an injection-safe string literal;
  zigmark never emits the mitex `#import` — consumers add it to their own
  preamble, using the new `docHasMath(&doc)` helper (exported from the root
  module and `typst`) to decide. HTML preserves the original `$…$` / `$$…$$`
  delimiters (HTML-escaped) so client-side KaTeX/MathJax keeps working; the
  Markdown renderer round-trips math verbatim; terminal/AI/AST renderers show
  the TeX source.
- **Markdown image alt text now maps to Typst `image(alt:)`** (both the
  `#figure(image(…))` and bare `#image(…)` forms), string-literal-escaped, and
  omitted when empty. Typst embeds it as the PDF alt text, which PDF/UA
  validation requires for images. Caption selection (title, else alt) is
  unchanged — the alt parameter is additive.

### Changed

- `inline.parseInlineElements` now takes an `Options` struct
  (`.{ .gfm, .math }`) instead of a bare `gfm: bool` (API break for direct
  callers of the inline parser; `Parser` usage is unaffected).

## [0.8.0] — 2026-07-13

Production security & quality hardening for public release. The HTML and Typst
renderers are now safe to point at untrusted Markdown, and the parser has
resource limits that turn pathological input into clean errors instead of
crashes.

### Security

- **XSS — dangerous URL schemes are now filtered by default.** Links, images,
  and autolinks whose destination scheme is `javascript:`, `vbscript:`,
  `file:`, or a non-image `data:` are emitted with an empty `href`/`src`.
  Detection normalises the scheme the way a browser does (leading control/space
  stripping, single-byte HTML-entity decoding so `java&#115;cript:` is caught,
  tab/newline/CR stripping). A denylist — not an allowlist — is used, so
  unknown-but-harmless schemes (e.g. the spec's `made-up-scheme://`) and
  `data:image/{png,gif,jpeg,webp}` still pass through, and CommonMark/GFM
  conformance is unchanged (652/652 + 24/24).
- **XSS — footnote labels are now HTML-escaped.** `footnote_reference` and
  `footnote_definition` previously interpolated the raw label into an attribute
  and element text, allowing markup injection; both are now escaped.
- **XSS — opt-in `safe` mode escapes raw HTML.** `html.Options{ .safe = true }`
  (also `zigmark.renderHtmlWithOptions`, the `zigmark_render_html_safe` C ABI
  export, and the CLI `--safe` flag) renders raw/inline HTML as visible text
  instead of passing it through. Default output is byte-identical to before, so
  spec conformance is preserved; downstream consumers of untrusted input should
  enable it.
- **Typst code injection — code spans and code blocks now use `raw()`.** Content
  is emitted via `#raw("…")` / `#raw(block: true, …)` with the text in a Typst
  string literal, so backticks or fences in the content can no longer break out
  into executable Typst markup (Typst runs at compile time and can read local
  files). Frontmatter-derived preamble fields are validated before
  interpolation: `fontsize` must be a length literal, colours must be hex, and
  string fields go through the string-literal escaper — invalid values fall
  back to safe defaults.
- **DoS — parser resource limits.** New `Parser.max_nesting_depth` (default
  128) turns deeply nested blockquotes, lists, and inline links/images into
  `error.NestingTooDeep` instead of a stack overflow; `Parser.max_input_bytes`
  (default 16 MiB, `0` = unlimited) bounds `parseMarkdown`/`parseFromReader`
  with `error.InputTooLarge`. Error paths now free the partial document/inline
  tree (no leak on a rejected parse).
- **Panic — ATX heading `#` counter no longer overflows.** A line of ≥256 `#`
  characters previously overflowed a `u8` in ReleaseSafe; counting now bails at
  7. Out-of-range frontmatter integers are coerced with `std.math.cast` instead
  of a panicking `@intCast`.
- **Frontmatter — malformed YAML no longer leaks or writes to stderr (#73).**
  A YAML parse failure previously leaked the parser's error bundle, asserted on
  parser internals, and printed diagnostics to stderr from library code — all
  removed. The CLI's `frontmatter`/`markdown` formats degrade gracefully
  (empty object / verbatim passthrough) instead of aborting. Note: the
  underlying rejection of a plain scalar containing an inline `" - "` is an
  upstream `zig-yaml` limitation and still needs a fork-level fix.

### Added

- `html.Options` / `renderToWriterWithOptions` / `renderWithOptions`,
  `zigmark.HtmlOptions` / `zigmark.renderHtmlWithOptions`, the
  `zigmark_render_html_safe` C ABI export, and the CLI `--safe` flag.
- `Parser.max_nesting_depth` / `Parser.max_input_bytes` (with
  `default_max_nesting_depth` / `default_max_input_bytes`).
- `src/markdown/security_test.zig` — a security-regression suite run by
  `zig build test`.
- Fuzz smoke check in CI (`zig build fuzz` as a flake check); new fuzz targets
  for safe-mode HTML, Typst document rendering, and ZON frontmatter.

### Fixed

- **Fuzz harness compiles again.** Every target used the pre-0.16
  `fn (void, []const u8)` signature and never built against Zig 0.16's
  `std.testing.fuzz`; targets now take a `*std.testing.Smith`. Fixed the
  `fuzz--fuzz` typo in the `fuzz` dev-shell app.

### Known limitations

- The inline link/emphasis scanner is O(n²) on pathological unmatched-bracket
  input, a CPU-DoS bounded (not eliminated) by `max_input_bytes`. Untrusted-
  input deployments should set a conservative `max_input_bytes` and a call-site
  timeout; a delimiter-stack rewrite is tracked for a follow-up.

## [0.7.4] — 2026-07-08

### Tests

- **Pinned the intentional raw-HTML drop in the Typst renderer.** The Typst
  renderer omits raw HTML with no Typst equivalent (block HTML is dropped
  whole; inline HTML drops the tags but keeps the enclosed text), while the
  HTML renderer preserves it. A downstream consumer (sc2in/policypress#117)
  depends on this to flag raw HTML in policy bodies, so a test now makes the
  contract explicit — if the behaviour ever changes, the failure surfaces
  here. Renderer behaviour is unchanged.

## [0.7.3] — 2026-07-03

### Changed

- Bumped the `pozeiden` lazy dependency to v0.2.0, bringing thread-safe
  rendering (threadlocal theme state, locked grammar init) and its Zig 0.16
  line into the CLI/WASM mermaid path. The dependency remains `lazy`, so
  library consumers still don't fetch it.

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
