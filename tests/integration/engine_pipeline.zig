const std = @import("std");
const World = @import("../../src/ecs/ecs.zig").World;
const Renderer = @import("../../src/graphics/renderer/render.zig").Renderer;
const JobSystem = @import("../../src/jobs/job_system.zig").JobSystem;
const EventBus = @import("../../src/events/event.zig").EventBus;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var w = World.init(allocator);
    const e = w.createEntity();

    var renderer = try Renderer.init(allocator);
    renderer.beginPass("integration");
    renderer.endPass();

    var jsys = try JobSystem.init(allocator);
    defer jsys.deinit();

    var bus = EventBus.init(allocator);
    bus.publish(.{ .id = 1, .payload = "integration" });

    std.debug.print("Pipeline integração OK — ECS:{d}, Renderer, Job, Event\n", .{e});
}
