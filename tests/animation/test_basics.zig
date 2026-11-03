const std = @import("std");
const AnimationSystem = @import("../../src/animation/animation.zig").AnimationSystem;

pub fn main() !void {
    var sys = AnimationSystem.init(std.heap.page_allocator);
    sys.play(.{ .name = "idle", .duration_ms = 250.0 });
    std.debug.print("Animation OK\n", .{});
}
