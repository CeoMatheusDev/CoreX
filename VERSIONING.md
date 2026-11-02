# CoreX product versioning and release policy

## One product identity

The repository-root `VERSION` file is the sole source of the CoreX Engine product version. Its current development identity is `0.1.0a1` (the starting value selected for this versioning rollout; it does not claim a historical published release).

Product versions are **not SemVer** and use the strict grammar:

```text
MAJOR.MINOR.PATCH{a|b|f|p}REVISION
```

Examples: `0.1.0a1`, `0.1.0b2`, `0.1.0f1`, `0.1.0p1`. Components are unsigned 32-bit decimal integers, with no leading zeroes except the value `0`. The channel revision is positive. Whitespace, newlines within the value, extra suffixes, unknown channels, and integer overflow are errors. `VERSION` contains exactly one such value and one trailing LF.

The native Zig parser/comparator is `shared/product_version.zig`: no external dependency, no allocation, checked numeric parsing, typed channels, and semantic ordering. It compares the numeric `major.minor.patch` tuple first, then channel `a < b < f < p`, then the channel revision. Therefore `0.1.0p99 < 0.1.1a1`.

## Allowed transitions

`corex-version bump ACTION` accepts only these transitions; every counter increment is overflow-checked:

| Action | Allowed source | Result |
| --- | --- | --- |
| `alpha` | `aN` | same line, `a(N+1)` |
| `beta` | `aN` or `bN` | `b1` from alpha; otherwise `b(N+1)` |
| `final` | `bN` | same line, `f1` |
| `patch-release` | `fN` or `pN` | `p1` from final; otherwise `p(N+1)` |
| `patch` | `fN` or `pN` | increment product PATCH; reset channel to `a1` |
| `minor` | `fN` or `pN` | increment MINOR, reset PATCH to 0 and channel to `a1` |
| `major` | `fN` or `pN` | increment MAJOR, reset MINOR/PATCH to 0 and channel to `a1` |

A prerelease must move alpha → beta → final; direct alpha → final, backward transitions, and stable-line bumps before finalization are rejected. A later `MAJOR.MINOR.PATCH` line starts at `a1`. Bumps never create Git tags, commits, GitHub releases, or release assets.

The bump command writes **only `VERSION`**, by atomic replacement, and accepts `--dry-run` to validate/print without writing. Compatibility policy and other files are not silently edited by a version bump. `corex-version release check` validates that the checked-out `VERSION` matches the tool's compiled identity and that the generated manifest and packaged presets satisfy their contracts; it performs no writes and creates no Git tag/release.

## Keeping the approved `.proj` schema

Package versions in the root/shared/editor/runtime `build.zig.zon` files remain package SemVer. Their `.version` fields are not product versions and are not rewritten by the release tool. The Zig toolchain, dependency pins and hashes likewise remain separate.

The approved `.proj` schemas are unchanged: `schema_version` remains an integer schema selector, and `engine.version` remains a SemVer string. Build code derives a deterministic SemVer **project requirement token** from `VERSION` for that existing field:

- `aN` → `MAJOR.MINOR.PATCH-alpha.N`
- `bN` → `MAJOR.MINOR.PATCH-beta.N`
- `f1` → `MAJOR.MINOR.PATCH`
- `fN` where N > 1 → `MAJOR.MINOR.PATCH+corex.fN`
- `pN` → `MAJOR.MINOR.PATCH+corex.pN`

This token is not a second product-version source. It is a schema-preserving wire representation. The generated distribution manifest records both it and the product version.

A project requirement equal to `project_engine_version` is `same_version`. A different SemVer is accepted only when its exact value appears in `compatible_project_engine_versions` in the manifest; that is `compatible`. Otherwise it is `incompatible`. The initial allow-list is empty (fail closed), so existing documents that still require the former `0.1.0` bootstrap identity are incompatible until that exact token is deliberately added to the allow-list or the project is explicitly updated. No automatic project rewrite/migration occurs. A valid manifest/table hash does not itself grant compatibility. Editor and Runtime share the same classifier. Compatibility does not imply that an unimplemented public core ABI has been checked.

## Generated build identity and distribution manifest

`shared/build.zig` reads and strictly validates root `VERSION`, injects the typed identity into `corex_app`, and generates the installed `share/corex/distribution.json` from `shared/fixtures/distribution.template.json`. The root legacy CoreX binary is injected from the same file. Editor and Runtime expose the compiled identity with `--version`; their normal JSONL startup/protocol continues to report `core_abi_checked=false` until that API exists.

Manifest `format_version` is independent of product version, package SemVer, `.proj` schema versions, graphics ABI, renderer contract, preset table revision, fingerprint format, dependencies, and Zig toolchain. The manifest validates its format, product version, project requirement, exact compatibility allow-list, renderer contract/table revision, and SHA-256 of the installed presets. A changed manifest is reported as `ManifestCorrupted`; missing/mismatched table resources or invalid contracts are `DistributionInvalid`. The manifest bytes are pinned to those generated into the executable. This detects inconsistent installation, not a maliciously replaced executable/manifest pair or authenticity; signing/updating remains outside this scope.

The shared fingerprint now has its own version 3 because the validated manifest payload changed. It reuses the existing fingerprint implementation; there is no parallel hash format.

## CoreX support policy

CoreX has its own policy; Unity support windows and LTS labels are not inherited. Alpha and beta builds are previews and have no compatibility or maintenance-window promise. CoreX does not designate an LTS line in this rollout. A final (`f`) or patch (`p`) build is supported only while its `MAJOR.MINOR` line is the latest final line; publishing a newer final line ends ordinary support for the previous line unless a future CoreX release explicitly documents an exception. A compatibility allow-list is a technical loading contract, not a support promise. No date-based support lifetime is claimed until CoreX publishes one for a particular line.

## Validation

Run the native Zig tests and both product builds; cross-compilation is compile evidence, not native Windows execution:

```sh
zig test shared/product_version.zig
(cd shared && zig build test)
(cd tools/zig && zig build test)
(cd editor && zig build test)
(cd runtime && zig build test)
(cd shared && zig build check -Dtarget=x86_64-windows-gnu)
```

The full commands and constraints are in [`versioning/README.md`](versioning/README.md). Release history is recorded in [`CHANGELOG.md`](CHANGELOG.md); no earlier CoreX product releases are inferred here.
