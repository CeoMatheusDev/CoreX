const std = @import("std");

pub const Event = struct {
    id: u32,
    payload: []const u8,
};

pub const EventBus = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EventBus {
        return .{ .allocator = allocator };
    }

    pub fn publish(self: *EventBus, evt: Event) void {
        _ = self;
        _ = evt;
    }
};
