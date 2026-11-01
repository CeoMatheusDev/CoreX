const std = @import("std");
const EventBus = @import("../../src/events/event.zig").EventBus;
const Event = @import("../../src/events/event.zig").Event;

pub fn main() !void {
    var bus = EventBus.init(std.heap.page_allocator);
    const evt = Event{ .id = 1, .payload = "teste" };
    bus.publish(evt);
    std.debug.print("Event Bus OK\n", .{});
}
