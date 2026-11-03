# CoreX Runtime

![Zig 0.17.0](https://img.shields.io/badge/Zig-0.17.0-f7a41d?logo=zig&logoColor=white) ![C23](https://img.shields.io/badge/C-C23-00599C?logo=c) ![Platforms](https://img.shields.io/badge/Platform-Linux%20%7C%20Windows-555)

Standalone Zig 0.17.0 + C23 project-validation bootstrap. It validates project configuration; it does not execute games.

> [!NOTE]
> Current capability: configuration validation only. No scene loading, gameplay loop, window, or graphics device is initialized.

---

> **Product scope:** Windows and Linux; 3D Editor with UI/Canvas, no 2D scene mode. Vulkan/OpenGL are planned on both platforms; D3D11/D3D12 are Windows-only. Eligibility does not imply a renderer exists. See [ADR-003](../docs/ADR-003-desktop-3d-canvas.md).

CoreXRuntime is a standalone Zig 0.17.0 + C23 project-validation bootstrap. **It does not execute games.** It does not link the legacy Engine, create a window or graphics device, or start a gameplay loop. Zigway remains the intended windowing dependency for future graphical integration.

## Build

Run from this directory:

```sh
zig build
zig build test
```

The build imports `../shared`, compiles C sources with `-std=c23`, and installs `zig-out/bin/CoreXRuntime` (`.exe` on Windows) together with `zig-out/share/corex/{distribution.json,presets.zon}`. The manifest and embedded product identity are generated from the repository-root `VERSION`. Missing or corrupt install data is an error; the Runtime does not fall back to the working directory or project directory.

## Validate a project

Run from the repository root:

```sh
runtime/zig-out/bin/CoreXRuntime --version
runtime/zig-out/bin/CoreXRuntime --project docs/examples/EmptyGame.proj --headless --validate-only
```

Validation reads the shared project schema, checks distribution identity, resolves presets and overrides, validates the C23 DTO, and writes JSON Lines logs with concrete configuration values. It emits `runtime.validation_complete`, **never `runtime.ready`**. It does not load scenes, assets, or scripts, negotiate the Core ABI, query a GPU, or simulate ticks. Success applies only to the document and presets.

Without `--validate-only`, including with `--headless`, execution fails explicitly with a core-unavailable error (exit code 4). This prevents an empty simulation from being presented as a functioning Player. C++/Lua integration, a fixed-timestep gameplay loop, jobs, hot reload, and game UI remain pending; Editor UI is not embedded in the Runtime.

The Runtime never writes `.proj` files. CLI options, exit codes, and protocol are documented in [APPLICATION_CLI.md](../docs/APPLICATION_CLI.md). Native Editor→Runtime process tests run with `python tools/test_bootstrap.py` from the repository root after building both applications. Native Windows execution is not currently available; a cross-build is not a substitute.

## Time scheduler (not integrated into gameplay)

`src/timing.zig` provides an integer accumulator with no internal allocation or clock. It uses the explicit 1–1000 Hz frequency from the schema and stores phase as `elapsed_ns * Hz`; one billion units correspond to one tick. This preserves the `1 / Hz` rate even when the frequency does not divide one second evenly in nanoseconds. The project configuration is not yet connected to this model in a running Runtime.

- `addElapsed` accepts a non-negative monotonic delta computed by a future loop. Overflow returns an error without changing state.
- `pending(budget)` reports whole ticks currently due, capped by the iteration budget. It is a query, not a reservation; apply the budget once per iteration.
- `nextTick` returns the zero-based next tick index or `null` when no tick is due. It reports counter exhaustion before work. Code using `commitTick` manually must check `nextTick` before running a tick and commit only after successful completion.
- `runDue` is an alternative that accepts an explicit callback, checks exhaustion before each call, and commits only successful calls up to the budget. If a callback fails, earlier ticks stay committed and the failed tick remains due. Recursive mutation/execution through scheduler methods is rejected during the callback. The callback must not mutate scheduler fields directly or access it concurrently. Callback side effects are not rolled back; after partial failure, the caller must provide transactionality or stop the session rather than blindly retry.
- `interpolationAlpha` returns `null` while ticks remain due; otherwise it returns the fraction in `[0, 1)`. This type does not store previous/current simulation state.

There is no automatic backlog discard. Pause/resume, clock and delta handling, recovery policy, delay telemetry, input ordering by tick, jobs, replay, and integration into a real game loop remain undefined or unimplemented. These arithmetic tests do not prove deterministic gameplay or permit `runtime.ready`.

## Tick-scoped input buffer (not a Zigway adapter or replay format)

`src/tick_input.zig` provides generic infrastructure for a future loop. It uses storage exclusively supplied by the caller and performs no internal allocation. Values are shallow-copied; the caller owns the lifetime of references inside `T`, and pointers/handles are not a persistent deterministic record.

`enqueue` and `enqueueBatch` accept nondecreasing tick indices and preserve input order within each tick. A batch is validated before copying: insufficient capacity, a past/out-of-order tick, or a tick that cannot be committed fails without partial insertion. Batch input must not alias the buffer's storage. Tick `maxInt(u64)` is rejected because the counter cannot advance beyond it.

`beginTick` opens only the next tick, including an empty tick, and detects overflow before work. The borrowed slice remains valid until `commitTick` or `abortTick`; callers must not mutate storage directly. `commitTick` removes the batch and advances, while `abortTick` retains it. The buffer is not thread-safe. Compaction costs O(backlog); the caller chooses capacity and backpressure behavior.

A test combines the buffer with `Scheduler.runDue` and simulates failure before external effects. In a future integration, input-buffer commit must be the **last infallible operation in the callback**: a later failure could advance the buffer without committing the scheduler. Abort does not reverse gameplay side effects; retry is safe only with a transaction or no partial effects. Mapping Zigway events to ticks, serialization, replay, clock policy, and gameplay integration remain pending.

## Known Zigway event-overflow limitation

The pinned Zigway `v0.1.0-alpha.4` null backend has a reproducible case where, with queue capacity 1, `key_down` followed by `key_up` evicts the first event while `droppedEvents()` remains zero. Therefore the counter does not detect every loss and cannot guarantee lossless input capture. The regression observation is in `src/zigway_input_tests.zig`; it does not test native windowing or fix Zigway upstream.
