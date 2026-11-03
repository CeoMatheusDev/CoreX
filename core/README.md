# CoreX Core

![Zig 0.17.0](https://img.shields.io/badge/Zig-0.17.0-f7a41d?logo=zig&logoColor=white)

Dependency-free foundation shared by the CoreX Editor and Runtime: application lifecycle, explicit subsystem ownership, and deterministic teardown.

> [!NOTE]
> Scope today is lifecycle and ownership only. There is no ECS, scene, job system, event bus, memory manager, window, platform handle, renderer, or GPU device here. The separate `scene/` package builds ECS and Scene on top of this lifecycle. See [ADR-006](../docs/ADR-006-core-library-and-headless-execution.md) and [ADR-008](../docs/ADR-008-scene-lifecycle-and-runtime-integration.md).

---

## Why a separate package

`shared/` holds application contracts (CLI, project schema, presets, C23 DTO, logging). It must stay usable by any application and must not inherit execution or graphics decisions. `core/` is the execution foundation instead, and applications depend on both:

```text
editor ─┐
        ├─ shared   (contracts)
runtime ┘   ├─ core   (lifecycle + subsystem registry)
            └─ scene  (ECS + Scene; depends only on core)
```

The Editor does not consume Core yet; the Runtime consumes both Core and Scene. `shared` never links either package.

The package has **no dependencies**, no C sources, and no build options. `minimum_zig_version` is `0.17.0`.

## Build and test

Run from this directory:

```sh
zig build test
zig build check
```

`test` runs the native tests; `check` only compiles them (usable for cross targets from the root build's `check` step).

## API

### `core.lifecycle`

`Lifecycle` is a narrow state machine: `created → starting → running → stopping → stopped`, with `failed` reachable from `starting` or `running`.

- An instance starts at most once; restarting requires a new instance, so resource ownership never becomes ambiguous.
- `beginStop` is allowed from `running` **and** from `failed`: a failed start or a failed step still has to release what it acquired.
- Every invalid transition returns `error.InvalidTransition` without mutating state.
- `stopped` is terminal: no transition leaves it.

### `core.subsystem`

`Subsystem.adopt(T, name, *T)` type-erases a value exposing `start()`, `step(Step)` and `stop()`. `start` and `step` may fail; `stop` cannot, because teardown must complete.

`Registry(capacity)`:

- fixed capacity known at compile time; **no allocator parameter exists**, so the step path cannot allocate;
- `register` rejects duplicate names (checked before capacity), rejects registration after start, and never reallocates;
- `start` runs subsystems in registration order and, on failure, stops the already-started ones in reverse order before propagating the original error unchanged (no retry, no partially-running state);
- `step(Step)` requires the `running` state; the first failing subsystem marks the instance `failed` and the error propagates;
- `stop` tears down in exact reverse registration order, is idempotent only in the sense of being rejected after `stopped`, and must still be called after a failed start.

Ownership rule: the registry stores a pointer to caller-provided state. Adopt values that live in a stable location for the whole run (a local in the function that owns the run, or a heap allocation kept alive) — never a temporary copy.

### `Step`

```zig
pub const Step = struct {
    index: u64, // zero-based, strictly sequential within a run
    dt_ns: u64, // constant for the whole run
};
```

The registry does not enforce those invariants itself; a consumer such as `runtime/src/run_mode.zig` verifies them with a dedicated subsystem so loop regressions surface as errors. The Runtime registers `runtime.input`, `runtime.scene` and `runtime.ledger` in that order; the Scene is an ordinary Core subsystem, not a second lifecycle.

## Tests

11 tests cover the transition matrix (including failed-start teardown and no resurrection), start/teardown ordering, rollback scope after a failed start, rejection of steps before start and after failure, capacity and duplicate-name rules, late registration, and an empty registry completing the lifecycle.

These tests validate ownership and ordering contracts only. They do not prove gameplay, rendering, or platform behavior.
