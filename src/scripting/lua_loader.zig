const std = @import("std");

pub const LuaLoader = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LuaLoader {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LuaLoader) void {
        _ = self;
    }

    pub fn load(self: *LuaLoader, runtime: anytype, path: []const u8) !void {
        _ = self;
        _ = runtime;
        _ = path;
    }
};
