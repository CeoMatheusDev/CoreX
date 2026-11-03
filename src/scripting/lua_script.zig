const std = @import("std");

pub const LuaScript = struct {
    source: []const u8,

    pub fn load(path: []const u8) !LuaScript {
        return .{ .source = path };
    }

    pub fn execute(self: *LuaScript) !void {
        _ = self;
    }
};
