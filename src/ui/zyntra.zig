// Integração CoreX ↔ ZyntraUI
// Versão de referência: v1.44.1 (MIT)
// Repositório: https://github.com/CeoMatheusDev/ZyntraUI

const std = @import("std");
const zyntra_ui = @import("zyntra_ui");

pub const Context = struct {
    ctx: zyntra_ui.Context,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, viewport: zyntra_ui.Rect) !Context {
        return .{
            .ctx = try zyntra_ui.Context.init(allocator, .{
                .viewport = viewport,
            }),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Context) void {
        self.ctx.deinit();
    }

    pub fn beginFrame(self: *Context) void {
        self.ctx.beginFrame();
    }

    pub fn endFrame(self: *Context) void {
        self.ctx.endFrame();
    }
};
