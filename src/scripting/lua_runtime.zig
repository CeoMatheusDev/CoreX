// Lua runtime: integração profunda com a arquitetura CoreX.
const std = @import("std");

const LuaState = @import("lua_state.zig").LuaState;
const LuaLoader = @import("lua_loader.zig").LuaLoader;

pub const LuaRuntime = struct {
    allocator: std.mem.Allocator,
    state: LuaState,

    pub fn init(allocator: std.mem.Allocator) !LuaRuntime {
        return .{
            .allocator = allocator,
            .state = try LuaState.init(allocator),
        };
    }

    pub fn deinit(self: *LuaRuntime) void {
        self.state.deinit();
    }

    pub fn loadScript(self: *LuaRuntime, path: []const u8) !void {
        const loader = LuaLoader.init(self.allocator);
        defer loader.deinit();
        try loader.load(self, path);
    }
};
