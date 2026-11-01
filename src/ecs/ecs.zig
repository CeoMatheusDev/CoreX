// ECS Core — CoreX
const std = @import("std");

pub const World = struct {
    allocator: std.mem.Allocator,
    next_entity_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .next_entity_id = 1,
        };
    }

    pub fn createEntity(self: *World) u32 {
        const id = self.next_entity_id;
        self.next_entity_id += 1;
        return id;
    }
};
