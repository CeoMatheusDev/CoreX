# CoreX Runtime

![Zig 0.17.0](https://img.shields.io/badge/Zig-0.17.0-f7a41d?logo=zig&logoColor=white) ![C23](https://img.shields.io/badge/C-C23-00599C?logo=c) ![Platforms](https://img.shields.io/badge/Platform-Linux%20%7C%20Windows-555)

Standalone Zig 0.17.0 + C23 project-validation bootstrap plus a deterministic headless frame loop. It validates project configuration and, when explicitly asked with `--frames`, executes a smoke scene or a limited JSON content scene through the Core lifecycle and Scene ECS, without a window or GPU; it does not execute games.

> [!NOTE]
> Current capability: configuration validation and a deterministic headless frame loop (`--frames`) over a smoke scene or an explicitly supplied, read-only content scene with hierarchy, 3D transforms and optional per-tick translation. No gameplay, window, graphics device or presented frame.

---

> **Product scope:** Windows and Linux; 3D Editor with UI/Canvas, no 2D scene mode. Vulkan/OpenGL are planned on both platforms; D3D11/D3D12 are Windows-only. Eligibility does not imply a renderer exists. See [ADR-003](../docs/ADR-003-desktop-3d-canvas.md).

CoreXRuntime is a standalone Zig 0.17.0 + C23 project-validation bootstrap. **It does not execute games.** It does not link the legacy Engine, create a window or graphics device, or run gameplay. Its headless loop (`--frames`) executes fixed-step accounting and real entities/components/systems, either from the embedded smoke scene or a limited `--scene` file. Zigway remains the intended windowing dependency for future graphical integration.

## Build

Run from this directory:

```sh
zig build
zig build test
```

The build imports `../shared`, `../core` and `../scene`, compiles C sources with `-std=c23`, and installs `zig-out/bin/CoreXRuntime` (`.exe` on Windows) together with `zig-out/share/corex/{distribution.json,presets.zon}`. The manifest and embedded product identity are generated from the repository-root `VERSION`. Missing or corrupt install data is an error; the Runtime does not fall back to the working directory or project directory.

## Validate a project

Run from the repository root:

```sh
runtime/zig-out/bin/CoreXRuntime --version
runtime/zig-out/bin/CoreXRuntime --project docs/examples/EmptyGame.proj --headless --validate-only
```

Validation reads the shared project schema, checks distribution identity, resolves presets and overrides, validates the C23 DTO, and writes JSON Lines logs with concrete configuration values. It emits `runtime.validation_complete`, **never `runtime.ready`**. It does not load scenes, assets, or scripts, negotiate the Core ABI, query a GPU, or simulate ticks. Success applies only to the document and presets.

Execution is opt-in through `--frames` (see below). Without it, execution requests — including with `--headless` — fail explicitly with a core-unavailable error (exit code 4). This prevents an empty simulation from being presented as a functioning Player. C++/Lua integration, full scene/asset loading, jobs, hot reload, and game UI remain pending; Editor UI is not embedded in the Runtime.

`shared/bootstrap.zig` defines an optional `Runner` contract (`RunRequest`, `RunReport`) and `entryWith`. The Runtime supplies its executor from `src/main.zig` and passes the allocator through `Runner.context`; `shared` itself never links Core or Scene, so an application without a runner keeps reporting `application.core_unavailable`. See [ADR-006](../docs/ADR-006-core-library-and-headless-execution.md) and [ADR-008](../docs/ADR-008-scene-lifecycle-and-runtime-integration.md).

The Runtime never writes `.proj` files. CLI options, exit codes, and protocol are documented in [APPLICATION_CLI.md](../docs/APPLICATION_CLI.md). Native Editor→Runtime process tests run with `python tools/test_bootstrap.py` from the repository root after building both applications. Native Windows execution is not currently available; a cross-build is not a substitute.

## Deterministic headless execution (`--frames`)

```sh
runtime/zig-out/bin/CoreXRuntime --project docs/examples/EmptyGame.proj --headless --frames 120
```

This is the Runtime's first real executor. `--frames` is Runtime-only, requires `--headless`, and cannot be combined with `--validate-only` or `--check-runtime`. It accepts 1 to 1 000 000 decimal frames; `0`, out-of-range and non-decimal values are CLI errors (exit code 2).

To load a content descriptor instead of the embedded smoke scene, append `--scene path/to/scene.json`. The path is relative to the working directory or absolute; `--scene` requires `--headless --frames N` and is Runtime-only. Input is limited to 4 MiB and is never written by the Runtime. Optional `parent_index` and `sibling_index` fields load parent/child links and preserve sibling order, including forward references; invalid indices, ordering and cycles are rejected. The optional `local_transform3d` component contains twelve flat i32 Q16.16 matrix fields with identity defaults; see the [Scene format and ownership notes](../scene/README.md#codec-de-transform-3d).

After loading, the Runtime computes world matrices parent-first. A node without a local transform passes its transformed parent's matrix through as an implicit identity; unrelated untransformed nodes have no world matrix. An optional scalar component `transform_velocity3d` moves an entity's local translation each fixed tick:

```json
{"entities":[{"components":[
  {"kind":"local_transform3d","m03":65536},
  {"kind":"transform_velocity3d","x":32768,"y":0,"z":-65536}
]}]}
```

`x`, `y` and `z` are raw signed i32 Q16.16 **deltas per tick**, expressed in the parent's coordinate space and added respectively to `m03`, `m13` and `m23`. Missing fields default to zero; floats, unknown fields and out-of-range values are rejected. The delta is constant, is not scaled by wall time and does not change rotation or scale. A velocity without a local transform is inert. Older strict Runtimes that do not recognize this component reject scenes containing it. After movement, only dirty subtrees are recomputed parent-first; overlapping marks are coalesced. Scalar `position` and `velocity` are independent. Authored `world_transform3d` and `transform_dirty` components are rejected as `InvalidTransformComponent`.

Local-coordinate and world-composition overflow report `TransformOverflow`; each entity's three local coordinates are checked before any is changed. The whole tick is not transactional: earlier entities and some computed worlds may already have changed when a later error occurs. The run fails without a final report and always tears down its resources.

`src/run_mode.zig` builds a `corex_core` `Registry` with three subsystems (`runtime.input`, `runtime.scene`, `runtime.ledger`) and drives them with the existing fixed-step scheduler:

- simulation rate 60 Hz; each frame credits exactly 16 666 667 ns of a **virtual** clock (1/60 s rounded up, so the accumulator keeps 20 phase units per frame instead of losing a fraction);
- at most 8 ticks per frame; overdue ticks stay in the accumulator instead of being discarded;
- `runtime.input` opens and commits one empty input tick per step, proving input and simulation ticks stay aligned; no input is staged in headless mode and staged input is rejected;
- `runtime.scene` is a `corex_scene` Scene owned by the Runtime. `runtime/src/headless_app.zig` declares 8 smoke entities with `Position`, `Velocity` and `Age`; `smoke.move` adds velocity to position and `smoke.age` increments the age. A third system applies optional 3D translation and propagates dirty transforms. Systems run in registration order; the scene is populated only after `registry.start()`;
- `runtime.ledger` rejects discontinuous step indices, a changing step duration and subsystem reuse;
- four independent counters (`steps`, scheduler `ticks`, `input_ticks`, ledger steps) must agree, otherwise the run fails with `error.AccountingMismatch` before anything is reported.

The allocator comes from `main` through `Runner.context`; child lists and reusable transform scratch are released on success and failure. For the fixed entities, component presence, hierarchy and velocities supported here, setup reserves dirty-store and traversal capacity, so ticks perform no allocation and read no wall clock. No retained traversal scratch is reserved when no entity has both a nonzero delta and a local transform; initial propagation can still allocate temporary storage. The 3D system scans dense velocities and visits affected subtrees and ancestors; the existing scalar systems also scan entity indices. Overall tick work is not generally O(number of dirty entities).

`Report` and `shared.bootstrap.RunReport` expose `entities_alive` and `state_checksum`. The checksum is FNV-1a 64 over entity handles and component presence/values in increasing entity-index order. Scenes without `transform_velocity3d`, including existing static 3D and hierarchy scenes, retain their previous checksums. The domain-separated `corex.hierarchy.v1\0` suffix includes parent/ordered-child handles; `corex.transform3d.v1\0` includes local/world matrix fields and dirty state. A new `corex.transform_velocity3d.v1\0` suffix appears only when that component exists and covers presence and all three deltas, including inert or zero velocities. Integers retain the existing host-endian encoding; this is not a portable cryptographic hash.

The executor emits `runtime.run_starting` and `runtime.run_complete` (or `runtime.run_failed`, exit code 70), with `scene="smoke"` by default or `scene="content"` when `--scene` is used, plus `gpu_created=false`, `window_created=false`, `presented_frames=0` and `play_started=false`. Checked additions return `PositionOverflow` or `AgeOverflow` rather than trapping on extreme content. Both coordinates are checked before updating an entity, but the whole tick is not transactional: earlier updates may already have occurred. The failed run is stopped and its state discarded, not retried or reported as complete.

Limits: content supports only the Runtime's scalar `position`, `velocity`, `age`, `transform_velocity3d`, parent/child links and `local_transform3d`. The `position` system does not inherit parent transforms. Dynamic 3D behavior is limited to constant translation per tick; there is no runtime reparenting, entity creation, rotation/scale animation, physics, asset/script loading, prefab, runtime export, job queue, real input, window, Vulkan device or presented frame. `--frames` proves fixed-step accounting, lifecycle, teardown, ECS state and determinism; it is not Play, gameplay or evidence of a renderer. The Editor rejects `--frames` and still reports `application.core_unavailable` for execution requests.

## Time scheduler (not integrated into gameplay)

`src/timing.zig` provides an integer accumulator with no internal allocation or clock. It uses the explicit 1–1000 Hz frequency from the schema and stores phase as `elapsed_ns * Hz`; one billion units correspond to one tick. This preserves the `1 / Hz` rate even when the frequency does not divide one second evenly in nanoseconds. Since this slice, `src/run_mode.zig` drives this model inside the headless executor; the rate is the loop's 60 Hz constant, not a value read from the project document.

- `addElapsed` accepts a non-negative monotonic delta computed by a future loop. Overflow returns an error without changing state.
- `pending(budget)` reports whole ticks currently due, capped by the iteration budget. It is a query, not a reservation; the headless loop applies the budget once per frame.
- `nextTick` returns the zero-based next tick index or `null` when no tick is due. It reports counter exhaustion before work. Code using `commitTick` manually must check `nextTick` before running a tick and commit only after successful completion.
- `runDue` is an alternative that accepts an explicit callback, checks exhaustion before each call, and commits only successful calls up to the budget. If a callback fails, earlier ticks stay committed and the failed tick remains due. Recursive mutation/execution through scheduler methods is rejected during the callback. The callback must not mutate scheduler fields directly or access it concurrently. Callback side effects are not rolled back; after partial failure, the caller must provide transactionality or stop the session rather than blindly retry.
- `interpolationAlpha` returns `null` while ticks remain due; otherwise it returns the fraction in `[0, 1)`. This type does not store previous/current simulation state.

There is no automatic backlog discard. Pause/resume, wall-clock and delta handling, recovery policy, delay telemetry, input ordering by tick, jobs, replay, full scene/asset loading, and presentation remain undefined or unimplemented. The headless executor now drives this model together with a Scene and its systems, but it does not prove deterministic gameplay, and nothing here permits `runtime.ready`.

## Tick-scoped input buffer (not a Zigway adapter or replay format)

`src/tick_input.zig` provides generic infrastructure for a future loop. It uses storage exclusively supplied by the caller and performs no internal allocation. Values are shallow-copied; the caller owns the lifetime of references inside `T`, and pointers/handles are not a persistent deterministic record.

`enqueue` and `enqueueBatch` accept nondecreasing tick indices and preserve input order within each tick. A batch is validated before copying: insufficient capacity, a past/out-of-order tick, or a tick that cannot be committed fails without partial insertion. Batch input must not alias the buffer's storage. Tick `maxInt(u64)` is rejected because the counter cannot advance beyond it.

`beginTick` opens only the next tick, including an empty tick, and detects overflow before work. The borrowed slice remains valid until `commitTick` or `abortTick`; callers must not mutate storage directly. `commitTick` removes the batch and advances, while `abortTick` retains it. The buffer is not thread-safe. Compaction costs O(backlog); the caller chooses capacity and backpressure behavior.

A test combines the buffer with `Scheduler.runDue` and simulates failure before external effects. In a future integration, input-buffer commit must be the **last infallible operation in the callback**: a later failure could advance the buffer without committing the scheduler. Abort does not reverse gameplay side effects; retry is safe only with a transaction or no partial effects. Mapping Zigway events to ticks, serialization, replay, clock policy, and gameplay integration remain pending.

## Known Zigway event-overflow limitation

The pinned Zigway `v0.1.0-alpha.4` null backend has a reproducible case where, with queue capacity 1, `key_down` followed by `key_up` evicts the first event while `droppedEvents()` remains zero. Therefore the counter does not detect every loss and cannot guarantee lossless input capture. The regression observation is in `src/zigway_input_tests.zig`; it does not test native windowing or fix Zigway upstream.
