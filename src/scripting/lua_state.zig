const std = @import("std");

pub const LuaState = struct {
    id: u32,

    pub fn init(allocator: std.mem.Allocator) !LuaState {
        _ = allocator;
        return .{ .id = 1 };
    }

    pub fn deinit(self: *LuaState) void {
        _ = self;
    }
};
