// Integração de janelas CoreX ↔ Zigway
const corex_platform = @import("corex_platform");
const zigway = @import("zigway");

pub const Window = struct {
    handle: zigway.Window,

    pub fn init(platform: *corex_platform.Platform, title: []const u8, width: u32, height: u32) !Window {
        return .{
            .handle = try platform.createWindow(.{
                .width = width,
                .height = height,
                .title = title,
                .resizable = true,
            }),
        };
    }

    pub fn deinit(self: *Window) void {
        self.handle.deinit();
    }
};
