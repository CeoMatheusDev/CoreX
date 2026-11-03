//! Editor lifecycle bridge: demonstrates Editor adopting core lifecycle + scene.
//! Not production gameplay; validates ownership/teardown contract.
const std = @import("std");
const core = @import("corex_core");
const scene = @import("corex_scene");

/// Minimal Editor lifecycle: created → starting → running → stopped.
/// The Editor uses Registry(3) to hold input/scene/ledger order,
/// matching the Runtime integration pattern but without headless --frames.
pub const EditorLifecycle = struct {
    lifecycle: core.lifecycle.Lifecycle = .{},
    registry: core.subsystem.Registry(3) = undefined,

    pub fn init() EditorLifecycle {
        return .{};
    }
};
