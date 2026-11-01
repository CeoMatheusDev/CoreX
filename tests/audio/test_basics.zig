const std = @import("std");
const AudioEngine = @import("../../src/audio/audio.zig").AudioEngine;

pub fn main() !void {
    var aud = try AudioEngine.init(std.heap.page_allocator);
    defer aud.deinit();
    aud.play("test.wav");
    std.debug.print("Audio OK\n", .{});
}
