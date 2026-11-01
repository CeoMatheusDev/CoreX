const std = @import("std");

pub const LuaEvent = struct {
    pub fn dispatch(event: []const u8) void {
        _ = event;
    }
};
