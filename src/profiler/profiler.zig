const std = @import("std");

pub const Profiler = struct {
    active: bool = false,

    pub fn init() Profiler {
        return .{};
    }

    pub fn start(self: *Profiler) void {
        self.active = true;
    }

    pub fn stop(self: *Profiler) bool {
        self.active = false;
        return true;
    }
};
