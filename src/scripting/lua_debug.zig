const std = @import("std");

pub const LuaDebug = struct {
    pub fn getStackTrace() []const u8 {
        return "Lua stack trace não implementado";
    }
};
