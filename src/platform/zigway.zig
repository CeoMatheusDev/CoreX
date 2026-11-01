// Integração CoreX ↔ Zigway
// Versão de referência: v0.1.0-alpha.4 (MIT)
// Repositório: https://github.com/CeoMatheusDev/Zigway

const std = @import("std");
const zigway = @import("zigway");

pub const Platform = struct {
    allocator: std.mem.Allocator,
    instance: zigway.Platform,

    pub fn init(allocator: std.mem.Allocator) !Platform {
        return .{
            .allocator = allocator,
            .instance = try zigway.Platform.init(allocator, .{}),
        };
    }

    pub fn deinit(self: *Platform) void {
        self.instance.deinit();
    }

    pub fn capabilities(self: *const Platform) zigway.Capabilities {
        return self.instance.capabilities();
    }
};
