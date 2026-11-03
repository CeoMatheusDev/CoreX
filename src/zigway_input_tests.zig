//! Observations against pinned Zigway; this is not a Runtime input adapter.
const std = @import("std");
const zigway = @import("zigway");

fn keyEvent(down: bool, window: ?zigway.WindowId) zigway.Event {
    const key = zigway.KeyEvent{ .window = window, .key = .escape, .modifiers = .{}, .repeat = false };
    return if (down) .{ .key_down = key } else .{ .key_up = key };
}

test "Zigway null delivers synthetic key events in order when not full" {
    var platform = try zigway.Platform.init(std.testing.allocator, .{ .backend = .null_backend, .event_queue_capacity = 4 });
    defer platform.deinit();
    var window = try platform.createWindow(.{ .title = "headless input test" });
    defer window.deinit();
    try std.testing.expectEqual(zigway.ActiveBackend.null_backend, platform.backendKind());
    platform.injectEvent(keyEvent(true, window.windowId()));
    platform.injectEvent(keyEvent(false, window.windowId()));
    try std.testing.expect(!platform.inputState().isKeyDown(.escape));
    try std.testing.expect((platform.nextEvent() orelse return error.MissingKeyDown) == .key_down);
    try std.testing.expect((platform.nextEvent() orelse return error.MissingKeyUp) == .key_up);
    try std.testing.expect(platform.nextEvent() == null);
    try std.testing.expectEqual(@as(u64, 0), platform.droppedEvents());
}

test "Zigway pinned overflow observation: eviction is not counted" {
    // Documents a v0.1.0-alpha.4 limitation, not desired product behavior.
    // If upstream fixes it, revise this test and the documented blocker.
    var platform = try zigway.Platform.init(std.testing.allocator, .{ .backend = .null_backend, .event_queue_capacity = 1 });
    defer platform.deinit();
    platform.injectEvent(keyEvent(true, null));
    platform.injectEvent(keyEvent(false, null));
    try std.testing.expect((platform.nextEvent() orelse return error.MissingKeyUp) == .key_up);
    try std.testing.expect(platform.nextEvent() == null); // key_down was evicted
    try std.testing.expectEqual(@as(u64, 0), platform.droppedEvents());
}
