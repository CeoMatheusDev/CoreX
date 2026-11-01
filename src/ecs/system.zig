const std = @import("std");

pub const System = interface {
    fn update(self: *@This(), dt: f32) void;
    fn init(self: *@This(), allocator: std.mem.Allocator) !void;
};
