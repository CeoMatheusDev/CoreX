const std = @import("std");

pub const LuaRegistry = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LuaRegistry {
        return .{ .allocator = allocator };
    }

    pub fn registerModule(self: *LuaRegistry, name: []const u8) void {
        _ = self;
        _ = name;
    }
};
