const std = @import("std");

// Audio System — CoreX
// Contrato básico: init/deinit, play, stop.

pub const AudioEngine = struct {
    allocator: std.mem.Allocator,
    enabled: bool = false,

    pub fn init(allocator: std.mem.Allocator) !AudioEngine {
        return .{
            .allocator = allocator,
            .enabled = true,
        };
    }

    pub fn deinit(self: *AudioEngine) void {
        self.enabled = false;
    }

    pub fn play(self: *AudioEngine, source: []const u8) void {
        _ = self;
        _ = source;
    }
};
