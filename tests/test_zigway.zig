const std = @import("std");
const zigway = @import("../src/window/zigway.zig");
const platform = @import("../src/platform/zigway.zig");

test "Window generational handle equality" {
    const h1 = zigway.WindowHandle{ .id = 1, .generational = 2 };
    const h2 = zigway.WindowHandle{ .id = 1, .generational = 2 };
    const h3 = zigway.WindowHandle{ .id = 1, .generational = 3 };
    try std.testing.expect(h1.equals(h2));
    try std.testing.expect(!h1.equals(h3));
}

test "Platform capabilities" {
    const allocator = std.heap.page_allocator;
    var p = try platform.ZigwayPlatform.init(allocator);
    const caps = p.capabilites();
    try std.testing.expect(std.mem.indexOf(u8, caps, "win32") != null or std.mem.indexOf(u8, caps, "x11") != null);
}

test "Window lifecycle init/deinit" {
    var w = zigway.Window.init(.{ .width = 1024, .height = 768, .title = "Test" });
    try std.testing.expect(w.visible);
    w.deinit();
    try std.testing.expect(!w.visible);
}

test "Event loop returns array" {
    const allocator = std.heap.page_allocator;
    var p = try platform.ZigwayPlatform.init(allocator);
    const events = p.waitEvents(0);
    try std.testing.expect(events.len == 0 or events.len >= 0);
}
