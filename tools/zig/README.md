# Zig tooling

This package builds the repository's native validation and release tools with Zig 0.17.0. Its checks validate contracts and policy; they do not establish GPU or native-window support.

## Product version and release checks

Build from the repository root:

```sh
(cd tools/zig && zig build)
tools/zig/zig-out/bin/corex-version version
tools/zig/zig-out/bin/corex-version compare 0.1.0a1 0.1.0b1
tools/zig/zig-out/bin/corex-version bump beta --dry-run
tools/zig/zig-out/bin/corex-version release check
```

A real version bump changes only `VERSION`. The release check validates the compiled product identity, generated manifest, and preset table. No command creates a tag, commit, or release. See [`../../VERSIONING.md`](../../VERSIONING.md) and [`../../versioning/README.md`](../../versioning/README.md).

## Native tooling validation

With Zig 0.17.0, run from `tools/zig`:

```sh
zig build validate -j2 --summary all
```

This executes tooling tests, fixture validation, and all six out-of-product target rejections using native executables. `validate-fixtures` and `validate-targets` can also be run individually. Validation steps reject custom `-Dtarget` and `-Dcpu`; `zig build check -Dtarget=x86_64-windows-gnu` remains compile-only and never runs a cross-compiled binary.

Fixture and target validators run on each invocation; they do not reuse a previous success. For a different checkout, use `zig build validate-fixtures -Drepository-root=/absolute/path/to/CoreX` or `zig build test-fixture-cli -Drepository-root=/absolute/path/to/CoreX`. Relative paths are resolved from `tools/zig`. From the repository root, `sh tools/test_zig_validate.sh /absolute/path/to/zig` exercises valid, corrupted, restored, and cross-target-rejection cases for validation and black-box tests.

## Preparing pinned legacy packages

`corex-extract-legacy` accepts only the Zigway and ZyntraUI releases whose SHA-256 values are compiled into the tool. It checks archive bytes before safe extraction; it is not a general-purpose extractor and does not protect against concurrent modification by a process controlling the parent directory.

Build and install only the extractor with:

```sh
cd tools/zig
zig build install-extractor
```

`tools/prepare_legacy_deps.sh` builds that tool through Zig Build, downloads the pinned archives or reads them from an offline archive directory, extracts them, and checks package hashes with `zig fetch`. The Python implementation remains a CI reference during migration. Dependency preparation details and limits are in [`../../docs/PYTHON_REMOVAL.md`](../../docs/PYTHON_REMOVAL.md).

## Project-contract fixture checker

With Zig 0.17.0 installed, run from the repository root:

```sh
zig run tools/zig/check_contract_fixtures.zig
zig test tools/zig/check_contract_fixtures.zig
zig test tools/zig/check_contract_fixtures.zig -O ReleaseSafe

(cd tools/zig && zig build)
python tools/test_fixture_checkers.py tools/zig/zig-out/bin/corex-check-fixtures
```

To select another checkout, run the compiled `corex-check-fixtures --root /absolute/path/to/CoreX`; `--help` shows syntax. By default, the tool uses the current working directory and reads files at runtime rather than embedding them. Each file is limited to 4 MiB; missing files or violations return a nonzero code.

The checker compares documented examples with packaged fixtures, validates `.proj` versions v1/v2/v3, backend ordering in v2/v3, the required `renderer.profile` enum in v3, and the preset SHA-256 against the manifest. It does not import application parsers. It checks consistency, not signatures, distribution security, complete JSON Schema compliance, or GPU operation. It rejects duplicate JSON keys and enforces expected schema numbers.

The workflow uses the Zig tool against real fixtures. Python remains the differential reference for isolated CLI cases; coverage does not prove complete parity. Some pipeline tools and CI tests still require Python even when Zig is installed.

`zig build test-fixture-cli` compiles and executes the real CLI against isolated copies of the nine fixtures, schemas, and manifest. Its 11 black-box tests cover missing files, mismatched pairs, invalid JSON, versions, backends, hashes, format, duplicate/escaped keys, arguments, diagnostic privacy, and the 4 MiB limit. A supervisor enforces a 20-second timeout and bounded stdout/stderr capture. Temporary copies are removed and checkout data is not modified. These tests are also part of `zig build test` and `zig build validate`; each invocation reruns them. The dedicated step rejects cross-targets. The tests do not invoke the Python reference, so differential parity remains a separate check.

Differential tests cover missing/corrupt files, mismatches, versions, backends, hashes, CLI behavior, and size limits. Known differences are intentional and documented: Zig rejects duplicate keys, non-integer or unsupported versions, and files above 4 MiB that Python may accept. On errors the Zig CLI reports the failing stage/files without printing input contents.

The former PR #4 was closed without merge; its reorganization is not part of this branch. Do not remove the Python reference until parity and coverage have been reviewed.

## Application target-policy checker

Run from `tools/zig` with an absolute Zig path:

```sh
zig build test --summary all
zig build --summary all
./zig-out/bin/corex-check-targets --root ../.. --zig /absolute/path/to/zig
```

On Windows, installed tools use `.exe`. The checker verifies the exact compiler version and runs the real Editor and Runtime `build check` commands for each of the three unsupported targets. For each target it requires both a normal nonzero exit and the expected policy message on stderr. A generic compile error, zero exit, or a message printed only to stdout is not accepted. It never executes a cross-compiled product.

Automated Linux tests use synthetic processes to cover a wrong Zig version, arguments/CWD, all six expected calls, zero exit with a diagnostic, incorrect diagnostics, and a message printed only to stdout. Testing with a real cross-target compiler is a separate operation.

The checker uses the shared subprocess supervisor without a shell for product commands: explicit executable path, bounded simultaneous capture of up to 256 KiB per pipe, and 120 seconds per target build (10 seconds for the version query). Cleanup after timeout depends on the OS. It terminates and reaps the immediate child, but does not guarantee descendant termination and is not a sandbox. Use only trusted compiler binaries. Linux supervisor tests use `/bin/sh` to simulate failures; the product checker does not invoke Zig through a shell.

Target validation in CI now uses this Zig tool; the corresponding Python checker was removed after parallel comparison and regression coverage. Other CI tools and tests still require Python. Windows was cross-compiled only; this tool has not been run natively on Windows.

## Linux CI output capture

`corex-ci-capture` is the Linux implementation used by the contracts workflow as a gradual replacement for the Python capture tool. The changed workflow still requires remote validation. See [`../CI_CAPTURE.md`](../CI_CAPTURE.md) for the protocol, tests, and limitations.

Windows is not implemented for this capture tool; a cross-compiled stub is not native support. `zig build test-capture-cli` runs 11 native Linux black-box tests without Python and is also part of `zig build test` and `zig build validate`. The dedicated step rejects cross-targets and non-Linux hosts; `check` only compiles for cross-targets. Tests use `/bin/sh`, `/bin/sleep`, and Linux `/proc` for probes and cleanup checks. They cover only part of the Python reference cases, so Python remains required in CI during the transition.
