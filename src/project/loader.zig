const std = @import("std");
const Config = @import("config.zig").ProjectConfig;

pub const ProjectLoader = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ProjectLoader {
        return .{ .allocator = allocator };
    }

    pub fn load(self: *ProjectLoader, path: []const u8) !Config {
        _ = self;
        _ = path;
        // Nota: leitura de arquivo .proj em desenvolvimento.
        // A base funcional retorna uma configuração padrão.
        return Config{
            .project = .{
                .name = "TestProject",
                .version = "1.0.0",
                .engine = "CoreX",
            },
            .graphics = .{
                .quality = "high",
                .api = "vulkan",
                .resolution = .{ .width = 1920, .height = 1080 },
                .vsync = true,
                .fullscreen = false,
                .window = .{ .x = 100, .y = 100 },
            },
            .physics = .{
                .fixed_timestep = 0.0166667,
                .gravity = .{ 0.0, -9.81, 0.0 },
            },
            .scripting = .{
                .language = "lua",
                .enabled = true,
            },
            .scenes = .{
                .startup = "Assets/Scenes/Main.scene",
            },
        };
    }
};
