<p align="center">
  <img src="assets/Logo minimalista COREX ENGINE.png" alt="CoreX Engine logo" width="720">
</p>

# CoreX Engine

![Zig 0.17.0](https://img.shields.io/badge/Zig-0.17.0-f7a41d?logo=zig&logoColor=white) ![C23](https://img.shields.io/badge/C-C23-00599C?logo=c) ![Platforms](https://img.shields.io/badge/Platform-Linux%20%7C%20Windows-555)

CoreX is an engine project in active development. The current repository provides independent Editor and Runtime validation bootstraps, a shared Core library (lifecycle and subsystem ownership), a Scene library (entities, sparse-set components, systems and scene lifecycle), shared project contracts, native validation tooling, and a separate legacy engine demonstration.

> [!NOTE]
> Current product boundary: project validation and a deterministic headless fixed-step loop with an embedded smoke scene are implemented; content-scene loading, a graphical Editor, playable Runtime, gameplay, and GPU presentation are not yet available.

---

> **Product scope:** Windows and Linux; a 3D Editor with UI/Canvas, no 2D scene mode. Vulkan/OpenGL are planned on both platforms; D3D11/D3D12 are Windows-only. A platform being eligible does not mean its renderer is implemented. See [ADR-003](docs/ADR-003-desktop-3d-canvas.md).

CoreX is a Zig 0.17.0 game-engine project in active development. The repository currently contains independent Editor and Runtime validation bootstraps, shared Core and Scene libraries, shared project contracts, and a separate legacy engine demonstration.

## Current implementation status

- **Editor and Runtime:** parse and validate project documents, presets, distribution identity, and the C23 graphics-configuration DTO. The Runtime can also run a deterministic headless fixed-step loop (`--frames`) that executes an embedded smoke scene with real entities, components, and systems. It reports `entities_alive` and `state_checksum`; it does not load content scenes, create a window or GPU device, or run a game. The Editor remains a validation bootstrap.
- **Shared contracts:** `.proj` schemas v1/v2/v3, preset validation, product identity, bootstrap protocol, and Zig↔C23 DTOs. See [`shared/README.md`](shared/README.md).
- **Legacy executable:** an independent demonstration using a null renderer. It is not the Editor or Runtime and does not prove GPU support.
- **Graphics:** there is no Vulkan Instance/Surface/Device/Swapchain or GPU presentation in the applications. The pinned Zigway window dependency does not currently expose the native-window contract required by CoreX Vulkan. See [ADR-005](docs/ADR-005-vulkan-surface-integration.md).

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
| Runtime | Project-validation bootstrap plus a deterministic headless fixed-step loop with an embedded smoke scene; no content-scene loading, window, GPU, or gameplay execution. [Build and usage](runtime/README.md) |
| Core | Lifecycle and subsystem ownership shared by Editor and Runtime; no graphics, platform, ECS, or job system. [API and rules](core/README.md) |
| Scene | Generational entities, sparse-set components, generic World, deterministic Systems and Scene lifecycle; depends only on Core. [API and rules](scene/README.md) |
| Shared | Schemas, presets, product identity, protocol, and C23 DTO. [Contracts and API](shared/README.md) |
| Versioning CLI | Validates and updates the root `VERSION`; does not create Git or GitHub releases. [Usage](versioning/README.md) |
| Zig tools | Fixture, target-policy, dependency-preparation, and CI-capture tooling. [Usage](tools/zig/README.md) |

## Pinned legacy integrations

The legacy build pins **Zigway v0.1.0-alpha.4** for window/input and **ZyntraUI v1.44.1** for UI-related experiments. CoreX's thin Zigway adapters have headless tests for explicit backend configuration, logical window lifecycle, event delivery, and input-state forwarding. These tests use Zigway's null backend; they do not exercise a native window or validate Vulkan.

Editor and Runtime are separate executables and do not currently share this legacy Engine or its window/UI integration. The dependency pins are not updated to an open, unvalidated Zigway branch.

## Project contracts and design records

- [Contributing guide](CONTRIBUTING.md)
- [Documentation index](docs/README.md)
- [Application CLI and protocol](docs/APPLICATION_CLI.md)
- [Application layout](docs/APPLICATION_LAYOUT.md)
- [Application progress and evidence](docs/APPLICATION_PROGRESS.md)
- [Scene API and rules](scene/README.md)
- [Project schema v1](docs/PROJECT_SCHEMA_V1.md) · [v2](docs/PROJECT_SCHEMA_V2.md) · [v3](docs/PROJECT_SCHEMA_V3.md)
- [Preset schema](docs/PRESETS_SCHEMA_V1.md)
- [Versioning policy](VERSIONING.md) · [Changelog](CHANGELOG.md)
- [Example project](exemploproject/README.md)

The example document can be validated by the Editor, but its referenced scene and assets are not loaded. Project validation is not evidence of a working game, graphical Editor, or GPU renderer.
