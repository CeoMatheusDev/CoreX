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

A project requirement equal to the compiled `project_engine_version` is `same_version`. A different SemVer is `compatible` only if it is in `shared/compatibility_policy.zig`, the allow-list compiled into the application; otherwise it is `incompatible`. The manifest's `compatible_project_engine_versions` is a declaration that must exactly match this independently compiled policy. It is never an authorization source and a self-added entry is rejected as manifest corruption. The production policy is empty (fail closed), so existing documents that still require the former `0.1.0` bootstrap identity are incompatible until that exact token is deliberately approved in the compiled policy and mirrored in the manifest. No automatic project rewrite/migration occurs. Hashes/fingerprints verify integrity or equivalence; neither grants compatibility. Editor and Runtime use the same compiled classifier. Compatibility does not imply that the unimplemented public core ABI has been checked.

## Generated build identity and distribution manifest

`shared/build.zig` reads and strictly validates root `VERSION`, injects the typed identity into `corex_app`, and generates the installed `share/corex/distribution.json` from `shared/fixtures/distribution.template.json`. The root legacy CoreX binary is injected from the same file. Editor and Runtime expose the compiled identity with `--version`; their normal JSONL startup/protocol continues to report `core_abi_checked=false` until that API exists. `--version` uses the usual JSONL envelope, so `timestamp`, `session_id`, and per-process sequence metadata intentionally vary; parity checks compare only stable `fields` identity/format values, not complete output lines.

Manifest `format_version` is independent of product version, package SemVer, `.proj` schema versions, graphics ABI, renderer contract, preset table revision, fingerprint format, dependencies, and Zig toolchain. The manifest validates its format, product version, project requirement, exact compatibility allow-list, renderer contract/table revision, and SHA-256 of the installed presets. A changed manifest is reported as `ManifestCorrupted`; missing/mismatched table resources or invalid contracts are `DistributionInvalid`. The manifest bytes are pinned to those generated into the executable. This detects inconsistent installation, not a maliciously replaced executable/manifest pair or authenticity; signing/updating remains outside this scope.

The shared fingerprint now has its own version 3 because the validated manifest payload changed. It reuses the existing fingerprint implementation; there is no parallel hash format.

## Trust boundary and compatibility matrix

`shared/compatibility_policy.zig` is the only production source of additional accepted project SemVers. It is compiled into Shared, Editor, and Runtime. Its current list is empty. The build-pinned manifest bytes are separately embedded; at runtime the distribution loader first requires exact byte equality, then validates typed fields and the presets SHA-256, and requires the manifest's compatibility declaration to equal the compiled policy. The classifier takes only the required project version and the compiled identity/policy—never the manifest. Thus changing the installed allow-list, adding fields, reformatting bytes, or recalculating a hash/fingerprint cannot expand authorization. A fingerprint is an unkeyed digest for comparing normalized configuration, not an authorization or signature.

| Project requirement | Compiled policy | Manifest | Integrity/format/schema | Result |
| --- | --- | --- | --- | --- |
| Equals compiled requirement | Any valid policy | Exact policy declaration | Valid | `same_version` |
| Different, not allow-listed | Empty/current policy | Exact policy declaration | Valid | `incompatible` |
| Different, test-only allow-listed | Isolated unit-test policy only | Exact declaration helper checked in the test | No production manifest altered | `compatible` only in the isolated classifier test |
| Any | Empty policy | Self-adds a version | Even with valid/recomputed presets SHA or configuration fingerprint | Manifest rejected; no authorization |
| Any | Any | Different bytes, malformed/duplicate/missing/extra/format/ABI-like fields | Any | `ManifestCorrupted` |
| Any | Any | Exact manifest but missing/mismatched table or invalid renderer contract | Any | `DistributionInvalid` |
| Any | Any | Valid distribution | Unsupported `.proj` schema | Project parser rejects before compatibility |
| Any | Any | Valid distribution | Public core ABI not defined/checked | `core_abi_checked=false`; no ABI compatibility claim |

The distribution manifest currently has no `abi_version`, `.proj schema_version`, or generic distribution fingerprint field. Renderer contract and `format_version` are distinct, validated fields. An injected `abi_version` or `fingerprint` is an unexpected field and is rejected; public ABI negotiation remains explicitly unimplemented rather than being represented by a fabricated identifier.

## Determinism scope

The generated `distribution.json` is assembled from a fixed LF template, canonical `VERSION`, the deterministic SemVer projection, a source-controlled ordered compatibility policy, and the SHA-256 of the approved `presets.zon`. Release stage/revision are encoded in `engine_version`; the current manifest has no separate component-version array or build-number field. Package/dependency versions remain in their own manifests. It contains no timestamps, absolute paths, machine/environment values, random identifiers, or Git metadata. Field order/whitespace come from the template; policy order is compile-controlled. ABI and `.proj` schema are intentionally not manifest fields; `.proj` schema is validated from the project document, while public ABI checking remains unavailable. The presets digest authenticates the table bytes against accidental/inconsistent changes, not publisher authenticity.

The runtime fingerprint is SHA-256 over typed, normalized `.proj` values, resolved parameters, and the validated manifest, serialized by a fixed Zig struct field order. Input JSON property order/format is normalized by parsing into the typed project model; numbers are represented by their validated target types. It excludes clocks, CWD, PIDs, sessions, and machine paths. The fingerprint identifies validation inputs, not executable bytes or every dependency/build input. No byte-for-byte binary reproducibility claim is made; repeat builds compare the manifest and exposed identity, not whole executable files.

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

Commandes, procedimentos Linux/Windows e estado de validação estão em [`docs/VERSIONING_VALIDATION.md`](docs/VERSIONING_VALIDATION.md) e [`versioning/README.md`](versioning/README.md). Release history is recorded in [`CHANGELOG.md`](CHANGELOG.md); no earlier CoreX product releases are inferred here.
