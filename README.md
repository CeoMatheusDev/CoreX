> **Product scope:** Windows and Linux; a 3D Editor with UI/Canvas, no 2D scene mode. Vulkan/OpenGL are planned on both platforms; D3D11/D3D12 are Windows-only. A platform being eligible does not mean its renderer is implemented. See [ADR-003](docs/ADR-003-desktop-3d-canvas.md).

# CoreX Engine

CoreX is a Zig 0.17.0 game-engine project in active development. The repository currently contains independent Editor and Runtime validation bootstraps, shared project contracts, and a separate legacy engine demonstration.

## Current implementation status

- **Editor and Runtime:** parse and validate project documents, presets, distribution identity, and the C23 graphics-configuration DTO. They do not provide a graphical Editor or run a game.
- **Shared contracts:** `.proj` schemas v1/v2/v3, preset validation, product identity, bootstrap protocol, and Zig↔C23 DTOs. See [`shared/README.md`](shared/README.md).
- **Legacy executable:** an independent demonstration using a null renderer. It is not the Editor or Runtime and does not prove GPU support.
- **Graphics:** there is no Vulkan Instance/Surface/Device/Swapchain or GPU presentation in the applications. The pinned Zigway window dependency does not currently expose the native-window contract required by CoreX Vulkan. See [ADR-004](docs/ADR-004-vulkan-surface-integration.md).

## Requirements

- Zig **0.17.0**; do not silently substitute another version.
- A C compiler with C23 support for the shared and application builds.
- Linux legacy window builds require X11 development libraries (for example, `libx11-dev` on Ubuntu). Headless tests do not open a display, but the legacy Zigway build still links X11.
- Python is still required by some CI and cross-process integration tests; see the [migration plan](docs/PYTHON_REMOVAL.md).

## Build and validation

After Zig is available and the pinned legacy packages have been prepared:

```sh
zig build -j2 --summary all
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build validate -j2 --summary all
```

To install the supported Zig wheel on Linux without Python and prepare the pinned packages:

```sh
mkdir -p .cache
sh tools/install_zig.sh "$PWD/.cache/zig-0.17.0"
ZIG_EXE="$PWD/.cache/zig-0.17.0/ziglang/zig"
sh tools/prepare_legacy_deps.sh --zig "$ZIG_EXE"
"$ZIG_EXE" build validate -j2 --summary all
```

For offline dependency preparation, provide verified archives with `--archive-dir`, containing `zigway.tar.gz` and `zyntra_ui.tar.gz`. The preparation script verifies both archive checksums and package hashes before initializing Zig's cache. See [tooling documentation](tools/zig/README.md) for details.

`zig build check -Dtarget=x86_64-windows-gnu` is compile-only. It is not a native Windows runtime test. Do not report a cross-build as validation of native windowing, Vulkan, or GPU presentation.

## Applications

| Component | Status and documentation |
| --- | --- |
| Editor | Project-validation bootstrap; no graphical UI or scene editing. [Build and usage](editor/README.md) |
| Runtime | Project-validation bootstrap; no game loop or gameplay execution. [Build and usage](runtime/README.md) |
| Shared | Schemas, presets, product identity, protocol, and C23 DTO. [Contracts and API](shared/README.md) |
| Versioning CLI | Validates and updates the root `VERSION`; does not create Git or GitHub releases. [Usage](versioning/README.md) |
| Zig tools | Fixture, target-policy, dependency-preparation, and CI-capture tooling. [Usage](tools/zig/README.md) |

## Pinned legacy integrations

The legacy build pins **Zigway v0.1.0-alpha.4** for window/input and **ZyntraUI v1.44.1** for UI-related experiments. CoreX's thin Zigway adapters have headless tests for explicit backend configuration, logical window lifecycle, event delivery, and input-state forwarding. These tests use Zigway's null backend; they do not exercise a native window or validate Vulkan.

Editor and Runtime are separate executables and do not currently share this legacy Engine or its window/UI integration. The dependency pins are not updated to an open, unvalidated Zigway branch.

## Project contracts and design records

- [Application CLI and protocol](docs/APPLICATION_CLI.md)
- [Application layout](docs/APPLICATION_LAYOUT.md)
- [Application progress and evidence](docs/APPLICATION_PROGRESS.md)
- [Project schema v1](docs/PROJECT_SCHEMA_V1.md) · [v2](docs/PROJECT_SCHEMA_V2.md) · [v3](docs/PROJECT_SCHEMA_V3.md)
- [Preset schema](docs/PRESETS_SCHEMA_V1.md)
- [Versioning policy](VERSIONING.md) · [Changelog](CHANGELOG.md)
- [Example project](exemploproject/README.md)

The example document can be validated by the Editor, but its referenced scene and assets are not loaded. Project validation is not evidence of a working game, graphical Editor, or GPU renderer.
