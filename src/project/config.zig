const std = @import("std");

pub const ProjectConfig = struct {
    project: struct {
        name: []const u8,
        version: []const u8,
        engine: []const u8,
    },
    graphics: struct {
        quality: []const u8,
        api: []const u8,
        resolution: struct {
            width: u32,
            height: u32,
        },
        vsync: bool,
        fullscreen: bool,
        window: struct {
            x: i32,
            y: i32,
        },
    },
    physics: struct {
        fixed_timestep: f64,
        gravity: [3]f64,
    },
    scripting: struct {
        language: []const u8,
        enabled: bool,
    },
    scenes: struct {
        startup: []const u8,
    },
};
