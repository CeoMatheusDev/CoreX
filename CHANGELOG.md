# Changelog

This file records notable CoreX product changes. `VERSION` is the product-version authority; the changelog does not create or imply a release. Historical implementation notes are kept separately in [`docs/CHANGES.md`](docs/CHANGES.md).

## Unreleased

- Added the root `VERSION` authority, strict native Zig parsing/comparison, validated release transitions, and the `corex-version` CLI with dry-run support.
- Injected the CoreX product identity into the root, Editor, and Runtime builds and added `--version` to the application executables.
- Generated and validated a distribution manifest with an explicit project-version compatibility allow-list; centralized Editor/Runtime compatibility classification and corruption/invalid-distribution diagnostics.
- Improved the CoreX Zigway adapters with explicit platform options and forwarding for window, event, input, and capability operations; added headless integration tests.
- Replaced obsolete Zigway tests and connected the adapter test artifact to the root test step.
- Reorganized and clarified project READMEs, architecture/status documentation, and the ADR index.
- Preserved package SemVer, `.proj` schema versions, renderer contract, graphics ABI, dependency pins, and Zig 0.17.0 as separate version domains.

No product release is created by an Unreleased entry. Release procedures are defined in [`VERSIONING.md`](VERSIONING.md).
