const std = @import("std");
const NullBackend = @import("../backends/null.zig").NullBackend;

pub const DrawCommand = struct {
    tag: u8 = 0,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    backend: NullBackend,

    pub fn init(allocator: std.mem.Allocator) !Renderer {
        return .{
            .allocator = allocator,
            .backend = try NullBackend.init(allocator),
        };
    }

    pub fn beginPass(self: *Renderer, pass_name: []const u8) void {
        _ = self;
        _ = pass_name;
    }

    pub fn endPass(self: *Renderer) void {
        _ = self;
    }

    pub fn submit(self: *Renderer, commands: []const DrawCommand) void {
        _ = self;
        NullBackend.submit(commands);
    }
};
