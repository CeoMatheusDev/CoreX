# CoreX Shared Contracts

![Zig 0.17.0](https://img.shields.io/badge/Zig-0.17.0-f7a41d?logo=zig&logoColor=white) ![C23](https://img.shields.io/badge/C-C23-00599C?logo=c) ![Platforms](https://img.shields.io/badge/Platform-Linux%20%7C%20Windows-555)

Reusable Zig 0.17.0 contract layer for project documents, presets, product identity, bootstrap protocol, and the private Zig-to-C23 graphics DTO.

> [!NOTE]
> Version domains are independent: product version, package SemVer, project schema, C ABI, and Zig toolchain versions must not be conflated.

---

`shared/` is the reusable Zig 0.17.0 contract layer for CoreX project documents (`.proj` v1/v2/v3), presets, the private Zig↔C23 graphics-configuration DTO, product identity, and bootstrap protocol. The independent Editor and Runtime bootstraps consume this package to validate documents; it does not depend on a window system, GPU, Lua, or the legacy application build.

Product version, package SemVer, project schema version, C ABI version, and toolchain version are distinct domains. Updating one does not implicitly update the others.

## Build and test

With Zig 0.17.0 installed:

```sh
cd shared
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build check -Dtarget=x86_64-windows-gnu -j2 --summary all
```

`check` compiles for another target without running the result. It is **not** a native Windows test. The first cross-link may take longer while the CRT is compiled.

On Linux, Zig 0.17.0 can be installed without Python using the repository installer:

```sh
# Run from the repository root; the destination must not already exist.
mkdir -p .cache
sh tools/install_zig.sh "$PWD/.cache/zig-0.17.0"
ZIG_EXE="$PWD/.cache/zig-0.17.0/ziglang/zig"
cd shared
"$ZIG_EXE" build test --summary all
```

The installer requires `curl`, `unzip`, `sha256sum`, and POSIX utilities; it can also use a locally downloaded wheel. Linux wheels are the supported installation path. macOS is outside the product scope (ADR-003); a native Windows wheel was not available for Zig 0.17.0 when this was documented. Do not silently substitute another Zig version.

To invoke the Zig test runner directly, including the C23 sources:

```sh
cd shared
zig test -I . -lc root.zig \
  -cflags -std=c23 -Wall -Wextra -Werror -- \
  graphics_abi.c platform_ext/process_native.c
```

From the repository root, additional checks are:

```sh
(cd tools/zig && zig build validate-fixtures)
zig fmt --check shared
c++ -std=c++20 -fno-rtti -fno-exceptions -Wall -Wextra -Werror \
  -fsyntax-only -x c++ shared/graphics_abi.h
```

The `shared-contracts.yml` workflow tests Debug and ReleaseSafe on Linux and cross-compiles Windows. Results tied to commits and CI links are recorded in [`../docs/APPLICATION_PROGRESS.md`](../docs/APPLICATION_PROGRESS.md); this is not the final CI matrix for both applications.

## Zig API and ownership

```zig
const app = @import("corex_app");

var diagnostic: app.project.Diagnostic = .{};
var document = try app.project.parse(allocator, project_bytes, &diagnostic);
defer document.deinit();

var table = try app.presets.parse(allocator, table_bytes);
defer table.deinit();

const resolved = try table.value.resolve(
    document.value.renderer.graphics_preset,
    document.value.renderer.overrides,
);
const dto = try app.graphics_abi.translate(resolved);
_ = dto; // consumed by a future core adapter; it does not create a renderer
```

`build.zig` exports the `corex_app` module. Consume it through the build graph so the C23 sources and libc linkage are included. C sources compile with `-std=c23 -Wall -Wextra -Werror`.

### Documents, presets, and graphics configuration

- `project.parse` performs a bounded preflight and strict typed parsing. It rejects duplicate keys, validates the version before the body, does not coerce strings/numbers, and checks metadata, lexical paths, and field dependencies.
- `Document` owns an arena. Its strings do not borrow the input byte buffer and remain valid until `deinit`. Do not copy the owning value and deinitialize both copies, or retain references after deinitialization.
- `project.serialize` allocates canonical bytes (two-space indentation, LF, final newline, optional equivalent fields omitted) and revalidates the document. The caller frees the returned slice with the same allocator. It does **not** write to disk or provide backup/atomic replacement.
- `Diagnostic.pointer()` formats a bounded RFC 6901 JSON Pointer in its own buffer and survives the parse error. Structural/semantic errors identify a field; syntax and duplicate-key errors currently report the root category without byte offsets. The caller adds the file path and human-readable message to its logger.
- `presets.parse` validates the restricted profile, envelope, complete presets, and invariants. Its arena owns strings and temporary parser diagnostics.
- `Table.resolve` performs name lookup in the configuration module, merges by field presence, and validates the resulting concrete configuration. Renderer quality lookup does not occur here.
- `graphics_abi.translate` validates and translates each field into an explicit C DTO. Flags and enums do not cross the ABI as internal Zig types.

Parsing may allocate while constructing a document; resolution and DTO translation do not allocate. This does **not** establish allocation behavior for core, Lua, or GPU subsystems that are not integrated here.

### Private C23 DTO

`graphics_abi.h` is an **internal application contract**. It is not the future public `engine_api.h` for the CoreX engine and does not create a renderer or graphics device. It uses a size/version header, fixed-width fields, 0/1 flags, explicit numeric enums, `i32` status, and no retained pointers or allocations.

The v1 DTO is 116 bytes with naturally aligned four-byte members and no packing. This costs a few bytes at initialization but avoids packed structs and language-dependent flags. C `static_assert`s and Zig tests verify offsets, natural alignment, and size; internal Zig types are never passed directly to C. Duplicated validation at the C boundary is defensive checking, not a second preset table.

## Bootstrap and process protocol

The package also provides the shared startup and validation contracts:

- `cli.zig`: strict shared argument parsing and explicit modes.
- `logging.zig`: fixed JSON Lines encoder and synchronous bootstrap sink; not a frame-time logger.
- `jsonl.zig`: incremental framing, bounds, and validation of received envelopes.
- `product_version.zig` and `engine_identity.zig`: typed product-version grammar and identity compiled from the root `VERSION`. `compatibility_policy.zig` is the trusted allow-list and currently starts empty; the manifest declaration is not authorization.
- `distribution.zig`: generated manifest, Editor/Runtime identity comparison, exact-or-allow-listed project compatibility, and preset-table SHA-256.
- `fingerprint.zig`: identity for the complete normalized configuration, excluding session/time/CWD. Fingerprint v4 distinguishes product/platform profile from requested Renderer and includes the expanded manifest.
- `bootstrap.zig`: orchestration shared by two independent executable entry points; it does not supply a fake core or renderer.
- `platform_ext/process.zig` and `process_native.c/.h`: bounded concurrent pipe capture, timeout, and ownership/reaping of the immediate child. `runCommand` supports tooling with explicit executable, argv, and CWD; it does not use a shell or supervise descendants. POSIX/Windows differences are isolated. The C module also compiles as C23.

Do not run untrusted programs with `--check-runtime`: the process helper is not a sandbox and does not supervise process trees. See [`../docs/APPLICATION_CLI.md`](../docs/APPLICATION_CLI.md) for CLI syntax, exit codes, examples, and limits; see [`../docs/ADR-002-validation-bootstrap.md`](../docs/ADR-002-validation-bootstrap.md) for design decisions and the resolved cancellation regression.

## Coverage and known limits

Tests cover project/preset parsing, memory round-trips for Editor/Runtime roles, invalid fields, escaped duplicate keys, decimal exactness, ownership, bounds, deterministic mutations, injected allocation failures, product identity and compatibility, manifest consistency, CLI/version transitions, and the real C23 ABI. The Editor/Runtime Zig tests include in-memory round-trips. In addition, `tools/test_bootstrap.py` exercises both built executables as separate processes during validation, including identity, process supervision, and JSON Lines. That process test currently uses Python.

Important limitations:

- **P14 — Unicode paths:** complete NFC normalization is unavailable. Non-ASCII filesystem paths fail closed with `UnicodePathNormalizationUnavailable`; UTF-8 project metadata and names are accepted. This is not complete support for all schema-allowed paths.
- **P14 — filesystem safety:** project paths are validated lexically only. Symlinks, actual case, permissions, existence, filesystem containment, and race-safe replacement require `platform_ext`. A parsed document does not authorize resource reads, writes, or execution.
- **P15 — partial:** distribution manifest/hash, CLI, synchronous logs, and validation bootstraps are integrated. The public Core ABI, real graphics capabilities/resources, frame-time/concurrent logging, Play, atomic persistence, and UI remain pending.
- **P04/P05/P06/P07/P09:** legacy builds/dependencies, GPU/reflection/jobs/VM, and the public engine API have remaining blockers recorded in the project docs.
- **P16:** native Windows execution and complete Windows application CI remain pending. Cross-compilation is not a substitute.

Approved contracts: [`../docs/PROJECT_SCHEMA_V1.md`](../docs/PROJECT_SCHEMA_V1.md), [`../docs/PRESETS_SCHEMA_V1.md`](../docs/PRESETS_SCHEMA_V1.md), and [ADR-003 desktop scope](../docs/ADR-003-desktop-3d-canvas.md). The v3 renderer-profile contract is in [`../docs/PROJECT_SCHEMA_V3.md`](../docs/PROJECT_SCHEMA_V3.md).
