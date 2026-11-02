const std = @import("std");
const Engine = @import("core/engine.zig").Engine;
const World = @import("ecs/ecs.zig").World;
const Job = @import("jobs/job.zig").Job;
const JobSystem = @import("jobs/job_system.zig").JobSystem;
const Renderer = @import("graphics/renderer/render.zig").Renderer;

test {
    _ = @import("events/event.zig");
    _ = @import("zigway_input_tests.zig");
}

test "legacy engine lifecycle toggles running" {
    var engine = try Engine.init(std.testing.allocator);
    try std.testing.expect(!engine.running);
    engine.tick();
    engine.start();
    try std.testing.expect(engine.running);
    engine.tick();
    engine.stop();
    try std.testing.expect(!engine.running);
}

test "legacy world allocates sequential identifiers" {
    var world = World.init(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), world.createEntity());
    try std.testing.expectEqual(@as(u32, 2), world.createEntity());
}

fn increment(context: *anyopaque) void {
    const count: *usize = @ptrCast(@alignCast(context));
    count.* += 1;
}

test "legacy job queue grows and invokes submitted jobs" {
    var jobs = try JobSystem.init(std.testing.allocator);
    defer jobs.deinit();
    var count: usize = 0;
    for (0..9) |_| {
        try jobs.submit(Job{ .name = "increment", .func = increment, .ctx = &count });
    }
    try std.testing.expect(jobs.capacity >= 9);
    try jobs.executeAll();
    try std.testing.expectEqual(@as(usize, 9), count);
}

test "legacy null renderer accepts a pass and draw command" {
    var renderer = try Renderer.init(std.testing.allocator);
    renderer.beginPass("test");
    renderer.submit(&.{.{ .tag = 1 }});
    renderer.endPass();
}

const Event = @import("events/event.zig").Event;
const EventBus = @import("events/event.zig").EventBus;
const EventJobContext = struct {
    jobs: *JobSystem,
    count: usize = 0,
    submit_failed: bool = false,
};
fn enqueueEventJob(ptr: *anyopaque, _: Event) void {
    const context: *EventJobContext = @ptrCast(@alignCast(ptr));
    context.jobs.submit(.{ .name = "event job", .func = increment, .ctx = &context.count }) catch {
        context.submit_failed = true;
    };
}

test "legacy event handler can enqueue work for later execution" {
    var jobs = try JobSystem.init(std.testing.allocator);
    defer jobs.deinit();
    var bus = try EventBus.init(std.testing.allocator, 2);
    defer bus.deinit() catch unreachable;
    var context: EventJobContext = .{ .jobs = &jobs };
    _ = try bus.subscribe(5, enqueueEventJob, &context);
    try bus.publish(.{ .id = 5, .payload = "first" });
    try bus.publish(.{ .id = 4, .payload = "ignored" });
    try bus.publish(.{ .id = 5, .payload = "second" });
    try std.testing.expect(!context.submit_failed);
    try std.testing.expectEqual(@as(usize, 0), context.count);
    try jobs.executeAll();
    try std.testing.expectEqual(@as(usize, 2), context.count);
    try jobs.executeAll();
    try std.testing.expectEqual(@as(usize, 2), context.count);
}
