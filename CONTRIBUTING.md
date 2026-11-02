# Contributing to CoreX

Thank you for helping improve CoreX. The repository is in active development; keep changes scoped, evidence-based, and compatible with the documented contracts.

## Toolchain and compatibility

- Use **Zig 0.17.0**. Do not silently substitute a different compiler version.
- Preserve the **C23** graphics-configuration ABI and its existing layout/validation guarantees unless an explicitly reviewed change requires otherwise.
- Keep CoreX product version, `.proj` schema version, preset format, renderer contract, ABI versioning, Zigway/ZyntraUI package versions, and Zig toolchain version as separate version domains.
- Do not change dependency pins or package hashes without auditing the release/source, recording the reason, and validating the resulting build. An open upstream branch is not a substitute for a published release.

## Implementation and validation expectations

- Make the smallest change that satisfies the requirement. Preserve ownership, error behavior, and public contracts; do not add guessed APIs or implicit fallback/downgrade behavior.
- Do not introduce stubs that simulate graphics, placeholder directories, or synthetic success states presented as delivered features.
- Keep the legacy CoreXEngine, Shared, Editor, Runtime, renderer profiles, quality presets, backend selection, and product/platform profiles distinct. A headless bootstrap or Null Backend is not evidence of a graphical application or GPU backend.
- For native graphics work, document window/Surface/Device ownership and destruction order. Validate real Surface, Device, Swapchain, and presentation before claiming Vulkan functionality. Cross-compilation is not native Windows validation.
- Do not claim a check passed unless it was run successfully. Report compiler version, target, Debug/ReleaseSafe mode, command, and whether execution was native or cross-compiled where relevant.

## Suggested local checks

Run the checks relevant to the changed modules. The repository README documents the full root build and validation commands; the application READMEs document their independent commands.

```sh
zig version
git ls-files -z '*.zig' | xargs -0 zig fmt --check
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build validate -j2 --summary all
git diff --check
```

The current repository has three legacy Zig files that are not parseable by Zig 0.17.0: `src/ecs/system.zig`, `src/memory/allocator.zig`, and `src/scripting/lua_allocator.zig`. Consequently, the global formatter command currently fails on those files. Do not hide that failure by omitting files from validation; report a scoped formatter check separately and preserve the blocker until the legacy contracts are reviewed.

The root build fetches pinned Zigway and ZyntraUI packages. If resolution fails, report the resolver error and stop rather than changing system DNS configuration, dependency pins, or retrying downloads indefinitely. Do not treat an unrun check as a pass.

## Documentation and design decisions

- Start at [`docs/README.md`](docs/README.md) for the documentation map and [`docs/STATUS.md`](docs/STATUS.md) for implementation boundaries.
- Update the relevant README and status/progress records when behavior or validation changes. Keep historical results labeled with their date/context; use the root [`CHANGELOG.md`](CHANGELOG.md) for notable product changes.
- Record material architectural changes in a numbered ADR. Do not reuse an ADR number; add the next available number and update the index.
- Describe planned, partial, headless, cross-compiled, and natively validated work distinctly. Never turn a proposal or source-file presence into a claim of delivered functionality.
