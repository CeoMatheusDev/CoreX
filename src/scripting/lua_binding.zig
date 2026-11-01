const std = @import("std");

pub const LuaBinding = struct {
    pub fn bindFunction(name: []const u8) void {
        _ = name;
    }
};
