# CoreX Versioning CLI

![Zig 0.17.0](https://img.shields.io/badge/Zig-0.17.0-f7a41d?logo=zig&logoColor=white) ![C23](https://img.shields.io/badge/C-C23-00599C?logo=c) ![Platforms](https://img.shields.io/badge/Platform-Linux%20%7C%20Windows-555)

Native Zig tooling for validating and updating the CoreX product version stored in the repository-root VERSION file.

> [!NOTE]
> The VERSION file is the single source of truth for the product version. Package versions remain independent.

---

The release format and transition policy are defined in [`../VERSIONING.md`](../VERSIONING.md). The repository-root `VERSION` file is the single source of the CoreX product version. Package versions are separate: do not edit package `.version` fields to mirror the product channel or revision.

## Build

Use Zig 0.17.0 from the repository root:

```sh
cd tools/zig
zig build
zig build test
cd ../..
```

The executable is `tools/zig/zig-out/bin/corex-version` (`.exe` on Windows). Run it from the repository root so `VERSION` is the only file it can update:

```sh
tools/zig/zig-out/bin/corex-version version
tools/zig/zig-out/bin/corex-version validate
tools/zig/zig-out/bin/corex-version compare 0.1.0a1 0.1.0b1
tools/zig/zig-out/bin/corex-version bump beta --dry-run
tools/zig/zig-out/bin/corex-version release check
```

## Commands and safety

`bump ACTION` applies a valid version transition and atomically replaces only `VERSION`. Review the proposed transition first; omit `--dry-run` only when it is intended. Supported actions are `alpha`, `beta`, `final`, `patch-release`, `patch`, `minor`, and `major`. Invalid transitions and numeric overflow fail without writing.

The CLI never invokes Git or creates tags, commits, GitHub releases, or release assets. It validates and edits version metadata only.

## Compiled identity and distribution manifest

The root build and the shared application build read the same `VERSION`. `CoreXEditor --version` and `CoreXRuntime --version` emit the identity compiled into each executable, together with the schema-preserving project-requirement token, as JSON Lines. `corex_app.engine_identity` exposes the typed identity to Zig consumers. By contrast, the CLI `version` command reads the current working tree; it does not report an already-built executable's embedded identity.

`distribution.json` is generated at build time from `VERSION` and `shared/fixtures/distribution.template.json`. Runtime compatibility authorization comes from the compiled allow-list in `shared/compatibility_policy.zig`; that list currently starts empty. The template is a declaration and must match the compiled policy, but it is not an authorization source. Changing the policy is a compatibility decision and requires tests and validation. Updating a manifest, hash, or fingerprint alone cannot authorize a different project version.

## Further documentation

- Release grammar and transition matrix: [`../VERSIONING.md`](../VERSIONING.md)
- Linux reproducibility and native-Windows validation status: [`../docs/VERSIONING_VALIDATION.md`](../docs/VERSIONING_VALIDATION.md)
- Application bootstrap and CLI contracts: [`../docs/APPLICATION_CLI.md`](../docs/APPLICATION_CLI.md)
