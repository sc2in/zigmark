# Security Policy

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

If you discover a security issue, please report it responsibly by emailing
**security@sc2.in** with:

- A description of the vulnerability
- Steps to reproduce
- Any relevant details (affected versions, exploitability, suggested fix)

You will receive acknowledgement within **72 hours** and we will work with you
on a fix before any public disclosure.

## Supported Versions

Security fixes are applied to the latest release only.  We do not backport
fixes to older versions.

## Scope

The following are in scope:

- Memory safety bugs in the parser (use-after-free, buffer over-read, etc.)
- Denial-of-service via crafted Markdown input (CPU or memory exhaustion)
- Incorrect HTML rendering that enables XSS in downstream applications
- Information disclosure via the C ABI

Out of scope: issues in transitive build-only dependencies that do not affect
the compiled output.

## Handling untrusted Markdown

When rendering Markdown from untrusted sources:

- **HTML output** — dangerous URL schemes (`javascript:`, `vbscript:`, `file:`,
  non-image `data:`) in links/images are neutralised by default. Raw HTML is
  passed through by default (CommonMark requires this); to neutralise it, render
  in **safe mode** — `html.Options{ .safe = true }` /
  `zigmark.renderHtmlWithOptions` / `zigmark_render_html_safe` /
  the CLI `--safe` flag — which escapes raw HTML to visible text.
- **Resource limits** — set `Parser.max_input_bytes` conservatively for your
  workload and rely on `Parser.max_nesting_depth` to bound recursion. Both turn
  pathological input into errors rather than crashes.
- **Typst output** — the Typst renderer escapes code content and validates
  frontmatter-derived preamble fields, but Typst still executes at compile time.
  Only compile renderer output you are willing to run; do not feed untrusted
  Typst to `typst compile` without sandboxing.

### Known limitations

- The inline scanner has O(n²) worst-case behaviour on pathological
  unmatched-bracket input. It is bounded by `max_input_bytes` but not
  eliminated; pair a conservative input cap with a call-site timeout for
  untrusted input.
