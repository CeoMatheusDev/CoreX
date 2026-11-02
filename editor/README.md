> **Product scope:** Windows and Linux; 3D Editor with UI/Canvas, no 2D scene mode. Vulkan/OpenGL are planned on both platforms; D3D11/D3D12 are Windows-only. Eligibility does not imply a renderer exists. See [ADR-003](../docs/ADR-003-desktop-3d-canvas.md).

# CoreXEditor

CoreXEditor is a standalone Zig 0.17.0 + C23 project-validation bootstrap. **It is not yet a graphical Editor.** This executable does not link the legacy CoreX Engine, Zigway, or ZyntraUI; those integrations remain separate work.

## Build and test

Run from this directory:

```sh
zig build
zig build test
```

The build imports `../shared`, compiles its C sources with `-std=c23`, and installs `zig-out/bin/CoreXEditor` (`.exe` on Windows). The install also contains a generated table and manifest under `zig-out/share/corex/`. Both the compiled product identity and manifest derive from the repository-root `VERSION`; keep the installed `share/corex/` tree alongside the executable.

Opening tests copy `../exemploproject/Example.proj` into a temporary directory and compile/use the real Editor. To select another example repository, pass `-Drepository-root=/absolute/path/to/CoreX` to `zig build test`. The tests rerun when the example changes. `zig build check` is compile-only, including for cross-targets.

## Validate a project

Run from the repository root:

```sh
editor/zig-out/bin/CoreXEditor --version
editor/zig-out/bin/CoreXEditor --project docs/examples/EmptyGame.proj --headless --validate-only
editor/zig-out/bin/CoreXEditor exemploproject/Example.proj --headless --validate-only
```

The `.proj` is read-only in this workflow. Output on stdout and stderr uses JSON Lines. The bootstrap validates the project and reports structured status; it does not open a UI, edit or save scenes, create backups, or perform atomic replacement. Requesting normal execution without `--validate-only` fails explicitly with exit code 4, including when `--headless` is supplied.

## Optional Runtime handshake

To compare the validated project with a separately built Runtime, provide a trusted executable:

```sh
editor/zig-out/bin/CoreXEditor \
  --project docs/examples/EmptyGame.proj \
  --validate-only \
  --check-runtime /absolute/path/to/CoreX/runtime/zig-out/bin/CoreXRuntime
```

This launches the supplied child process; use only a trusted binary. The child is invoked with `--headless --validate-only`. The Editor captures both pipes, validates the protocol, and requires an identical fingerprint of the full configuration. The check has a 10-second deadline, bounded capture, and reaps the immediate child. It does not supervise a process tree or guarantee cleanup after abrupt Editor termination. This handshake is validation, not Play.

CLI options, exit codes, and protocol limits are specified in [APPLICATION_CLI.md](../docs/APPLICATION_CLI.md). Cross-process tests are run with `python tools/test_bootstrap.py` from the repository root after building both applications.

## Project-opening and resource work

The workspace model in `src/workspace.zig` supports domain/tool state without allocating scene data: switching between 3D transforms and Canvas layout resets the active tool, and an incompatible operation returns an error without mutating state. It is not connected to UI panels and does not edit real scenes.

`src/project_preflight.zig` contains a tested concurrent task for reading and validating the project document, but it is not connected to the bootstrap or UI. `src/resource_discovery.zig` discovers the four required roots, checks existence/type/containment after symlink resolution, and indexes bounded, sorted metadata for regular files and subdirectories under `assets.root`. Traversal uses directory handles without following symlinks; file and directory symlinks are rejected. Existing resource paths are checked for containment and type. Missing resources remain logical tickets until loaders exist.

`src/project_opening.zig` coordinates discovery through `Opening.startDiscovery()` and `pollDiscovery()`. Its snapshot exposes discovery state; `assetInventory()` and `assetDirectoryInventory()` provide read-only views; `assetChildren()` iterates immediate children without allocation; and `Discovery.findAsset()` / `findAssetDirectory()` perform exact lookups. Snapshot-verification methods expose invalidation changes; they do not replace the future loader's security checks.

Discovery does not read, decode, or execute resource contents. `Opening.openAsset()` opens an indexed asset, while `openResourceFile()` opens an existing scene/script/library read-only through handles that do not follow symlinks. `readAssetAlloc()` and `readResourceAlloc()` copy opaque bytes under a caller-supplied limit; they do not interpret the format. `resource_discovery.AssetReadTask` performs a worker read, and `startAssetRead()` / `takeAssetRead()` support one outstanding task at a time, publish status/error, and require collection before the inventory is released. Direct use requires a live, thread-safe `Discovery` and allocator.

Ticket-completion and readiness tests remain synthetic. They are not evidence of a scene/asset loader, graphical UI, or real services. Project opening is still disconnected from the bootstrap and UI. See [ADR-004: project opening and splash](../docs/ADR-004-project-opening-splash.md) for decisions and remaining work.

## Project association

The Editor accepts a `.proj` path as a positional argument for future operating-system file association and refuses to start without a project. Passing a path does not register that association. The 800×600 splash screen, graphical Editor, and normal project-opening experience are not implemented.
