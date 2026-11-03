const std = @import("std");

const Stage = enum {
    Init,
    Running,
    Stopped,
};

pub const Lifecycle = struct {
    stage: Stage = .Init,
};

pub fn LifecycleInit() Lifecycle {
    return .{};
}

pub fn LifecycleStart(self: *Lifecycle) void {
    self.stage = .Running;
}

pub fn LifecycleStop(self: *Lifecycle) void {
    self.stage = .Stopped;
}

pub fn LifecycleUpdate(self: *Lifecycle) void {
    if (self.stage == .Running) {
        // Tick principal
    }
}
