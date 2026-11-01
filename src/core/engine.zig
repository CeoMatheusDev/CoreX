const std = @import("std");
const LifecycleModule = @import("lifecycle.zig");
const Lifecycle = LifecycleModule.Lifecycle;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    running: bool = false,
    lifecycle: Lifecycle,

    pub fn init(allocator: std.mem.Allocator) !Engine {
        return Engine{
            .allocator = allocator,
            .running = false,
            .lifecycle = Lifecycle{},
        };
    }

    pub fn start(self: *Engine) void {
        self.running = true;
        LifecycleModule.LifecycleStart(&self.lifecycle);
    }

    pub fn stop(self: *Engine) void {
        self.running = false;
        LifecycleModule.LifecycleStop(&self.lifecycle);
    }

    pub fn tick(self: *Engine) void {
        if (!self.running) return;
        LifecycleModule.LifecycleUpdate(&self.lifecycle);
    }
};
