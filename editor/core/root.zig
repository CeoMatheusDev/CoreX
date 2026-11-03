//! Editor Core integration package: bridges core lifecycle + scene ECS into the Editor.
//! Pure Zig; depends only on corex_core and corex_scene.
const std = @import("std");
const core = @import("corex_core");

pub const Lifecycle = core.lifecycle.Lifecycle;
pub const Registry = core.subsystem.Registry;
pub const Step = core.subsystem.Step;

pub const Scene = @import("corex_scene").Scene;

pub const EditorSubsystem = struct {
    name: []const u8,
    start_fn: *const fn (*anyopaque) anyerror!void,
    step_fn: *const fn (*anyopaque, Step) anyerror!void,
    stop_fn: *const fn (*anyopaque) void,
    context: *anyopaque,
};

pub const EditorContext = struct {
    allocator: std.mem.Allocator,
};
