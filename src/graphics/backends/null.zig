// Backend Null — validação de contrato do renderer sem GPU.
// Quando implementado para Vulkan, este arquivo será substituído
// por `src/graphics/backends/vulkan.zig` sem alterar `render.zig`.

const std = @import("std");
const DrawCommand = @import("./../renderer/render.zig").DrawCommand;

pub const NullBackend = struct {
    pub fn init(allocator: std.mem.Allocator) !NullBackend {
        _ = allocator;
        return .{};
    }

    pub fn submit(commands: []const DrawCommand) void {
        _ = commands;
    }
};
