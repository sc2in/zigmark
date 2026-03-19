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
