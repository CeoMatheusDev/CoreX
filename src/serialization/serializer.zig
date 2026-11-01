const std = @import("std");

pub const Serializer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Serializer {
        return .{ .allocator = allocator };
    }

    pub fn serializeInt(self: *Serializer, val: i32, out: []u8) []const u8 {
        _ = self;
        _ = val;
        return out[0..0];
    }
};
