# Contributing to zigmark

Thank you for taking the time to contribute to zigmark. This project is maintained by Star City Security Consulting (SC2, [https://sc2.in](https://sc2.in)) and prefers minimal process, high quality, and secure design.

## Get started

1. Fork the repository.
2. Create a feature branch: `git checkout -b fix/whatever`
3. Build and test locally:

```bash
zig build test
nix run .#bench   # optional performance checks
```

1. Commit with clear message and include issue reference (if any):

- `feat: add ...`
- `fix: correct ...`
- `docs: update ...`

1. Open a pull request from your branch to `main`.

## Development workflow

- Keep PRs focused and small.
- Rebase or merge `main` before final review.
- Include test coverage or update tests for behavior changes.
- Use existing style in Zig code and no trailing whitespace.

## Testing

- Core test suite: `zig build test`.
- CommonMark/GFM spec tests:
  - `zig build spec`
  - `zig build gfm`
- Fuzz harness (if modifying parser): `zig build fuzz`

## Issues

- Use GitHub issues for bug reports and enhancement ideas.
- Provide a minimal reproduction case and expected vs actual behavior.

## SC2 ideals

- Security: avoid introducing unsafe memory models or undefined behavior.
- Reliability: prefer stable, well-tested APIs.
- Simplicity: avoid overengineering; keep public API lean.

## Release notes

Follow `CHANGELOG.md` conventions; record notable changes at the corresponding version section. (A maintainer may adapt as needed.)
