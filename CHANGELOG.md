# Changelog

This file records notable CoreX product changes. `VERSION` is the product-version authority; the changelog does not create or imply a release. Historical implementation notes are kept separately in [`docs/CHANGES.md`](docs/CHANGES.md).

## Unreleased

- Added the root `VERSION` authority, strict native Zig parsing/comparison, validated release transitions, and the `corex-version` CLI with dry-run support.
- Injected the CoreX product identity into the root, Editor, and Runtime builds and added `--version` to the application executables.
- Generated and validated a distribution manifest with an explicit project-version compatibility allow-list; centralized Editor/Runtime compatibility classification and corruption/invalid-distribution diagnostics.
- Improved the CoreX Zigway adapters with explicit platform options and forwarding for window, event, input, and capability operations; added headless integration tests.
- Replaced obsolete Zigway tests and connected the adapter test artifact to the root test step.
- Reorganized and clarified project READMEs, architecture/status documentation, and the ADR index.
- Recovered the legacy ECS system contract and the legacy memory and Lua allocator modules for Zig 0.17.0; they are now compiled and covered by 15 new tests, and their paths are part of the formatting gate. They remain unused by the Editor, Runtime, and legacy executable.
- Preserved package SemVer, `.proj` schema versions, renderer contract, graphics ABI, dependency pins, and Zig 0.17.0 as separate version domains.
- Replaced the placeholder pool descriptor in the legacy core with a working `PoolAllocator` (fixed blocks, alignment-aware stride, LIFO reuse, invalid-free detection, fixed capacity) and added a `PoolRegistry` that reuses pools per geometry and routes frees to the owning pool, covered by 11 new legacy tests. Both remain unused by the Editor, Runtime, and legacy executable.
- Added a native Zig port of the Editor/Runtime integration suite (`tools/zig/test_bootstrap_cli.zig` plus the test-only `bootstrap_probe.zig`): 33 black-box tests over real processes, JSONL, distribution integrity, deadlines, capture limits, and child cleanup, runnable with `zig build test-bootstrap-cli` on POSIX hosts. The Python reference remains in CI until remote validation.

No product release is created by an Unreleased entry. Release procedures are defined in [`VERSIONING.md`](VERSIONING.md).
