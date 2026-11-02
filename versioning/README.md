# CoreX versioning tooling

The product release format and policy are normative in [`../VERSIONING.md`](../VERSIONING.md). Root `VERSION` is the only product-version source. Do not edit package `.version` fields to mirror its channel suffix.

## Build the native Zig CLI

With the repository-pinned Zig 0.17.0:

```sh
cd tools/zig
zig build
zig build test
cd ../..
```

The executable is `tools/zig/zig-out/bin/corex-version` (Windows builds use `.exe`). Run commands from the repository root so the only writable target is `./VERSION`:

```sh
tools/zig/zig-out/bin/corex-version version
tools/zig/zig-out/bin/corex-version validate
tools/zig/zig-out/bin/corex-version compare 0.1.0a1 0.1.0b1
tools/zig/zig-out/bin/corex-version bump beta --dry-run
tools/zig/zig-out/bin/corex-version release check
```

`bump ACTION` applies the transition and atomically replaces only `VERSION`; omit `--dry-run` only when the displayed transition is intended. Actions are `alpha`, `beta`, `final`, `patch-release`, `patch`, `minor`, and `major`. Invalid transitions and overflow fail without writing. The utility never invokes Git, creates tags, commits, releases, or assets.

## Binary identity

The root build and shared application build read the same root `VERSION`. `CoreXEditor --version` and `CoreXRuntime --version` emit the compiled product identity and its schema-preserving project-requirement token as JSON lines. `corex_app.engine_identity` exposes the typed identity to Zig code. The CLI `version` command reads the current working tree's `VERSION`; it is distinct from an already compiled binary's embedded version.

## Manifest compatibility

`distribution.json` is generated at build time from `VERSION` plus `shared/fixtures/distribution.template.json`. The template's `compatible_project_engine_versions` list is an explicit exact-match allow-list, separate from the current product identity. It starts empty. Editing that list is a compatibility decision requiring validation/tests; merely producing a valid SHA-256 does not authorize a different project version. The `.proj` schemas and package manifests remain unchanged.

The manifest format, compatibility status model, support policy, and validation matrix are documented in `../VERSIONING.md`. Do not claim native Windows runtime validation from a Windows cross-build.
