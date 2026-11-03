//! Headless integration tests for CoreX's thin Zigway adapters.
const std = @import("std");
const corex_platform = @import("corex_platform");
const corex_window = @import("corex_window");
const zigway = @import("zigway");

test "CoreX platform adapter supports an explicit headless backend" {
    var platform = try corex_platform.Platform.initWithOptions(
        std.testing.allocator,
        .{ .backend = .null_backend },
    );
    defer platform.deinit();

    try std.testing.expectEqual(zigway.ActiveBackend.null_backend, platform.backendKind());
    const capabilities = platform.capabilities();
    try std.testing.expect(!capabilities.clipboard);
    try std.testing.expect(!capabilities.video_modes);
}

test "CoreX platform adapter preserves Zigway config validation" {
    try std.testing.expectError(
        error.InvalidConfig,
        corex_platform.Platform.initWithOptions(
            std.testing.allocator,
            .{ .backend = .null_backend, .event_queue_capacity = 0 },
        ),
    );
}

test "CoreX platform adapter forwards events and synchronized input state" {
    var platform = try corex_platform.Platform.initWithOptions(
        std.testing.allocator,
        .{ .backend = .null_backend },
    );
    defer platform.deinit();
    var window = try corex_window.Window.init(&platform, "input test", 320, 200);
    defer window.deinit();

    platform.instance.injectEvent(.{ .key_down = .{
        .window = window.handle.windowId(),
        .key = .escape,
        .modifiers = .{},
        .repeat = false,
    } });
    try std.testing.expect(platform.inputState().isKeyDown(.escape));

    platform.pollEvents();
    try std.testing.expectEqual(@as(u32, 0), platform.waitEvents(0));
    try std.testing.expect((platform.nextEvent() orelse return error.MissingKeyEvent) == .key_down);
    try std.testing.expect(platform.nextEvent() == null);
    try std.testing.expectEqual(@as(u64, 0), platform.droppedEvents());
}

test "CoreX window adapter creates and destroys its Zigway handle" {
    var platform = try corex_platform.Platform.initWithOptions(
        std.testing.allocator,
        .{ .backend = .null_backend },
    );
    defer platform.deinit();

    var window = try corex_window.Window.init(&platform, "CoreX headless test", 640, 360);
    defer window.deinit();

    try std.testing.expect(window.handle.isValid());
    window.deinit();
    try std.testing.expect(!window.handle.isValid());

    // Window.deinit is intentionally safe when a defer runs after explicit
    // destruction; the wrapper delegates that idempotence to Zigway.
    window.deinit();
    try std.testing.expect(!window.handle.isValid());
}
