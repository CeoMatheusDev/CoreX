// Animation System — CoreX
const std = @import("std");

pub const Animation = struct {
    name: []const u8,
    duration_ms: f32,
};

pub const AnimationSystem = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AnimationSystem {
        return .{ .allocator = allocator };
    }

    pub fn play(self: *AnimationSystem, anim: Animation) void {
        _ = self;
        _ = anim;
    }
};
