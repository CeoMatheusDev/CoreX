# CoreX Example Project

![Zig 0.17.0](https://img.shields.io/badge/Zig-0.17.0-f7a41d?logo=zig&logoColor=white) ![C23](https://img.shields.io/badge/C-C23-00599C?logo=c) ![Platforms](https://img.shields.io/badge/Platform-Linux%20%7C%20Windows-555)

A minimal CoreX project document used to exercise project discovery and validation.

> [!NOTE]
> The sample directories are organizational placeholders, not loadable scenes, assets, or scripts.

---

`Example.proj` is a CoreX schema v2 project document for exercising project discovery and validation. The `scenes/`, `assets/`, and `scripts/` directories are organizational starting points; their README files are documentation, not loadable game content.

## Validate the project

From the repository root, after building the Editor with Zig 0.17.0:

```sh
editor/zig-out/bin/CoreXEditor exemploproject/Example.proj --headless --validate-only
```

This checks the project document, distribution identity, and presets. It does **not** load scene, asset, or script content.

## Current limitations

- The project names `scenes/Main.scene` as its startup path, but no scene format, scene file, or scene loader is implemented.
- The graphical Editor, splash screen, and normal project-opening flow are not available; normal execution reports that the core is unavailable.
- Passing a `.proj` path does not register a file association with the operating system.

See the Editor opening design and remaining work in [`../docs/ADR-004-project-opening-splash.md`](../docs/ADR-004-project-opening-splash.md).
