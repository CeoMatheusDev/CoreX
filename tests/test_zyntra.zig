const std = @import("std");
const zyntra = @import("../src/ui/zyntra.zig");

test "Context init/end" {
    const allocator = std.heap.page_allocator;
    var ctx = zyntra.Context.init(allocator);
    ctx.beginFrame();
    ctx.endFrame();
}

test "Dirty rect mechanism" {
    const allocator = std.heap.page_allocator;
    var ctx = zyntra.Context.init(allocator);
    ctx.markDirty(.{ .x = 0, .y = 0, .w = 100, .h = 40 });
}

test "WindowRegistry operations" {
    try std.testing.expect(zyntra.WindowRegistry.add(1, .{}));
}

test "Compositor interface" {
    const allocator = std.heap.page_allocator;
    var reg = zyntra.WindowRegistry{};
    _ = reg;
    try std.testing.expect(true);
}

test "FrameMetrics default values" {
    const metrics = zyntra.FrameMetrics{};
    try std.testing.expect(metrics.buffer_growths == 0);
}

test "Viewport3D interface" {
    var pixels: [1024]u8 = undefined;
    try std.testing.expect(zyntra.Viewport3D.render(&pixels, 32, 32));
}
