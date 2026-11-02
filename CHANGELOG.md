# Changelog

All notable CoreX product changes will be recorded here. This file starts with the versioning infrastructure; it intentionally does not reconstruct or imply a prior product-release history.

## Unreleased

- Added the root `VERSION` authority with a strict native Zig parser/comparator, checked release transitions, and a `corex-version` CLI with dry-run support.
- Injected CoreX product identity into root, Editor, and Runtime builds; added `--version` to the application binaries.
- Generated and validated a distribution manifest with an explicit project-version compatibility allow-list; centralized Editor/Runtime compatibility classification and distinct corruption/invalid-distribution diagnostics.
- Preserved package SemVer, `.proj` schema versions, renderer contract, graphics ABI, dependency pins, and Zig 0.17.0 as separate version domains.
