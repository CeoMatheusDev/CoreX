const std = @import("std");
const EventBus = @import("../../src/events/event.zig").EventBus;
const Event = @import("../../src/events/event.zig").Event;

fn count(context: *anyopaque, _: Event) void {
    const calls: *usize = @ptrCast(@alignCast(context));
    calls.* += 1;
}

pub fn main() !void {
    var bus = try EventBus.init(std.heap.page_allocator, 8);
    defer bus.deinit() catch unreachable;
    var calls: usize = 0;
    _ = try bus.subscribe(1, count, &calls);
    try bus.publish(.{ .id = 1, .payload = "teste" });
    std.debug.assert(calls == 1);
    std.debug.print("Event Bus OK: {d} entrega\n", .{calls});
}
